import Foundation

/// One call track's capture for live transcription: placed on the session clock by the same
/// `TrackTimeline` arithmetic as the track writer, so its times are the track file's times, and
/// resampled to the 16 kHz the pipeline reads. Unbounded: a slow model makes it grow (ADR-0020).
final class LiveTrackFeed: CallAudioSink, @unchecked Sendable {
    let audio: DecodedAudio
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private let lock = NSLock()
    private var timeline: TrackTimeline
    private var resampler = PCMResampler(inputRate: AssetCallTrackWriter.sampleRate,
                                         outputRate: Double(AVAssetMediaDecoder.sampleRate))

    init(sessionStart: TimeInterval) {
        let (chunks, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        audio = DecodedAudio(duration: 0, startOffset: 0, chunks: chunks)
        self.continuation = continuation
        timeline = TrackTimeline(sampleRate: AssetCallTrackWriter.sampleRate,
                                 sessionStart: sessionStart)
    }

    var startOffset: TimeInterval? {
        lock.withLock { timeline.startOffset }
    }

    func consume(_ samples: [Float], at time: TimeInterval) {
        // An empty chunk would claim the track's first sample without any audio, as in the writer.
        guard !samples.isEmpty else { return }
        let output = lock.withLock {
            let pad = timeline.place(frames: samples.count, at: time)
            return resampler.resample([Float](repeating: 0, count: pad) + samples)
        }
        if !output.isEmpty { continuation.yield(output) }
    }

    func finish() {
        continuation.finish()
    }
}
