import Foundation

/// A stream of everything a long file produces, in order: the file opened, each transcribed
/// segment, and how far decoding has got.
enum LongAudioEvent: Sendable, Equatable {
    /// Once, first: the whole file's duration.
    case opened(duration: TimeInterval)
    /// A transcribed segment, timed from the start of the FILE (decoder `startOffset` added).
    /// `text` is the provider's output trimmed of whitespace; never empty — empty results
    /// are not emitted.
    case segment(start: TimeInterval, end: TimeInterval, text: String)
    /// After each decoded chunk: seconds from the start of the file decoded so far.
    case position(TimeInterval)
}

/// Turns one file into a stream of events for a controller to consume: it opens the file, decodes
/// it chunk by chunk, finds the speech in each chunk, transcribes every segment (retrying a
/// transient failure), and reports how far it has got. Audio is held one chunk at a time — a chunk
/// is transcribed before the next is pulled — but the events it yields are buffered without bound,
/// so a slow consumer never slows the producer: decoding and transcription run at the provider's
/// pace regardless. The producing task stops when the stream is terminated (the consumer's task
/// cancelled), at the next segment.
struct LongAudioPipeline: Sendable {
    /// Three attempts in total: the first call plus two retries.
    private static let attempts = 3

    private let decoder: any MediaAudioDecoding
    private let segmenter: any SpeechSegmenting
    private let transcriber: @Sendable () async throws -> any TranscriptionProvider
    private let language: String?
    private let retryDelay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void

    init(decoder: any MediaAudioDecoding,
         segmenter: any SpeechSegmenting,
         transcriber: @escaping @Sendable () async throws -> any TranscriptionProvider,
         language: String?,
         retryDelay: Duration = .seconds(1),
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.decoder = decoder
        self.segmenter = segmenter
        self.transcriber = transcriber
        self.language = language
        self.retryDelay = retryDelay
        self.sleep = sleep
    }

    /// Finishes normally at the end of the file. Throws the decoder's or segmenter's error,
    /// or the provider's error after three attempts. Terminating the stream (the consumer's
    /// task cancelled) cancels decoding and transcription.
    func run(_ url: URL, from start: TimeInterval) -> AsyncThrowingStream<LongAudioEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoded = try await decoder.open(url, from: start)
                    continuation.yield(.opened(duration: decoded.duration))
                    // Sessions are not Sendable and keep state between chunks, so the session is
                    // built here, inside the one task that drives the stream.
                    let session = try segmenter.makeSession()
                    // Obtained once per run, on first use: a file with no speech never builds one.
                    var provider: (any TranscriptionProvider)?
                    let offset = decoded.startOffset
                    let rate = Double(AVAssetMediaDecoder.sampleRate)
                    var decodedSeconds: TimeInterval = 0

                    for try await chunk in decoded.chunks {
                        try Task.checkCancellation()
                        decodedSeconds += Double(chunk.count) / rate
                        for segment in session.accept(chunk) {
                            // A terminated stream stops at the next segment, not the next chunk.
                            try Task.checkCancellation()
                            if provider == nil { provider = try await transcriber() }
                            guard let provider else { continue }
                            try await emit(segment, from: provider, offset: offset,
                                           into: continuation)
                        }
                        continuation.yield(.position(offset + decodedSeconds))
                    }
                    // The decoder's stream is over; whatever speech was still open is drained
                    // exactly like a chunk's segments.
                    for segment in session.finish() {
                        // A terminated stream stops at the next segment, not the next chunk.
                        try Task.checkCancellation()
                        if provider == nil { provider = try await transcriber() }
                        guard let provider else { continue }
                        try await emit(segment, from: provider, offset: offset, into: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // A consumer that stops pulling (or whose task is cancelled) stops decoding too.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Transcribes one segment and yields it, timed from the start of the file. An empty result
    /// (after trimming) is dropped: the provider heard nothing worth keeping.
    private func emit(_ segment: SpeechSegment,
                      from provider: any TranscriptionProvider,
                      offset: TimeInterval,
                      into continuation: AsyncThrowingStream<LongAudioEvent, Error>.Continuation)
        async throws {
        let text = try await transcribe(segment.samples, with: provider)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        continuation.yield(.segment(start: offset + segment.start,
                                    end: offset + segment.end,
                                    text: trimmed))
    }

    /// One segment's text, retried on a transient failure. Cancellation is never retried: it is
    /// the consumer giving up, not the provider stumbling.
    private func transcribe(_ samples: [Float],
                            with provider: any TranscriptionProvider) async throws -> String {
        var attempt = 1
        while true {
            do {
                return try await provider.transcribe(samples,
                                                     sampleRate: AVAssetMediaDecoder.sampleRate,
                                                     language: language)
            } catch {
                guard attempt < Self.attempts, Self.isRetryable(error) else { throw error }
                try await sleep(retryDelay)
                attempt += 1
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? MacomprendoError, error == .cancelled { return false }
        return true
    }
}
