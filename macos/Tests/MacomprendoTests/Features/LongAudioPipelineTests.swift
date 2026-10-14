import Foundation
import Testing
@testable import Macomprendo

@Suite struct LongAudioPipelineTests {

    // MARK: - Helpers

    private static let url = URL(fileURLWithPath: "/tmp/long-audio-pipeline-test.m4a")

    /// One second of 16 kHz mono at a fixed level.
    private static func second(_ level: Float = 0.1) -> [Float] {
        [Float](repeating: level, count: AVAssetMediaDecoder.sampleRate)
    }

    /// A one-second segment starting at `start` seconds into the decoded stream.
    private static func segment(at start: TimeInterval) -> SpeechSegment {
        SpeechSegment(start: start, samples: second(), sampleRate: AVAssetMediaDecoder.sampleRate)
    }

    private func make(decoder: ScriptedMediaDecoder,
                      segmenter: ScriptedSegmenter,
                      transcriber: @escaping @Sendable () async throws -> any TranscriptionProvider,
                      language: String? = "en",
                      retryDelay: Duration = .seconds(1),
                      sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in })
        -> LongAudioPipeline {
        LongAudioPipeline(decoder: decoder, segmenter: segmenter, transcriber: transcriber,
                          language: language, retryDelay: retryDelay, sleep: sleep)
    }

    private func collect(_ stream: AsyncThrowingStream<LongAudioEvent, Error>) async throws
        -> [LongAudioEvent] {
        var events: [LongAudioEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    /// Runs the stream to the end, returning everything it emitted and the error it ended with.
    private func outcome(of stream: AsyncThrowingStream<LongAudioEvent, Error>) async
        -> (events: [LongAudioEvent], error: Error?) {
        var events: [LongAudioEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    /// Records the durations a retry was told to wait, and returns instantly.
    private final class SleepSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var _durations: [Duration] = []
        var durations: [Duration] { lock.withLock { _durations } }
        func sleep(_ duration: Duration) async throws {
            lock.withLock { _durations.append(duration) }
        }
    }

    /// A provider that returns one scripted outcome per call, in order.
    private final class SequenceProvider: TranscriptionProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [Result<String, Error>]
        private var _received: [FakeTranscriptionProvider.Call] = []

        init(_ outcomes: [Result<String, Error>]) { self.outcomes = outcomes }

        var received: [FakeTranscriptionProvider.Call] { lock.withLock { _received } }

        func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
            lock.withLock {
                _received.append(.init(pcm: pcm, sampleRate: sampleRate, language: language))
            }
            let outcome = lock.withLock { outcomes.isEmpty ? nil : outcomes.removeFirst() }
            switch outcome ?? .success("") {
            case .success(let text): return text
            case .failure(let error): throw error
            }
        }
    }

    /// A decoder whose chunk stream reports the moment the pipeline stops pulling from it: the
    /// deterministic signal that the producing task has ended. The stream is never finished, so
    /// it ends only when the pipeline drops it and the termination handler fires exactly then.
    private final class TerminatingDecoder: MediaAudioDecoding, @unchecked Sendable {
        let stopped = AsyncGate()
        private let chunks: [[Float]]

        init(chunks: [[Float]]) { self.chunks = chunks }

        func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio {
            let chunks = self.chunks
            let stopped = self.stopped
            let stream = AsyncThrowingStream<[Float], Error> { continuation in
                continuation.onTermination = { _ in stopped.open() }
                for chunk in chunks { continuation.yield(chunk) }
            }
            return DecodedAudio(duration: 10, startOffset: start, chunks: stream)
        }
    }

    // MARK: - Tests

    @Test func emitsOpenedSegmentsAndPositionsInOrder() async throws {
        let decoder = ScriptedMediaDecoder(duration: 10, chunks: [Self.second(), Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)], [Self.segment(at: 1)]])
        let provider = FakeTranscriptionProvider()

        let events = try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider })
                .run(Self.url, from: 0))

        #expect(events == [
            .opened(duration: 10),
            .segment(start: 0, end: 1, text: "hello"),
            .position(1),
            .segment(start: 1, end: 2, text: "hello"),
            .position(2),
        ])
    }

    @Test func segmentTimesIncludeTheResumeOffset() async throws {
        let decoder = ScriptedMediaDecoder(duration: 300, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 2)]])
        let provider = FakeTranscriptionProvider()

        let events = try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider })
                .run(Self.url, from: 120))

        #expect(events.contains(.segment(start: 122, end: 123, text: "hello")))
        #expect(events.first == .opened(duration: 300))
    }

    @Test func emptyTranscriptionsAreNotEmitted() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)]])
        let provider = FakeTranscriptionProvider()
        provider.result = .success("   ")

        let events = try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider })
                .run(Self.url, from: 0))

        #expect(events == [.opened(duration: 5), .position(1)])
    }

    @Test func aFailingSegmentIsRetriedTwiceThenThrows() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)]])
        let provider = FakeTranscriptionProvider()
        provider.result = .failure(MacomprendoError.providerUnreachable(endpointName: "Ollama (local)"))
        let sleeper = SleepSpy()

        let result = await outcome(of: make(decoder: decoder, segmenter: segmenter,
                                            transcriber: { provider },
                                            retryDelay: .milliseconds(7),
                                            sleep: { try await sleeper.sleep($0) })
            .run(Self.url, from: 0))

        #expect(provider.received.count == 3)
        #expect(sleeper.durations == [.milliseconds(7), .milliseconds(7)])
        #expect(result.events == [.opened(duration: 5)])
        #expect(result.error as? MacomprendoError
                == .providerUnreachable(endpointName: "Ollama (local)"))
    }

    @Test func aSegmentThatSucceedsOnRetryIsEmitted() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)]])
        let provider = SequenceProvider([
            .failure(MacomprendoError.providerUnreachable(endpointName: "Ollama (local)")),
            .success("second try"),
        ])
        let sleeper = SleepSpy()

        let events = try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider },
                 retryDelay: .milliseconds(7), sleep: { try await sleeper.sleep($0) })
                .run(Self.url, from: 0))

        #expect(provider.received.count == 2)
        #expect(sleeper.durations == [.milliseconds(7)])
        #expect(events == [
            .opened(duration: 5),
            .segment(start: 0, end: 1, text: "second try"),
            .position(1),
        ])
    }

    @Test func cancellationIsNotRetried() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)]])
        let provider = FakeTranscriptionProvider()
        provider.result = .failure(CancellationError())
        let sleeper = SleepSpy()

        let result = await outcome(of: make(decoder: decoder, segmenter: segmenter,
                                            transcriber: { provider },
                                            sleep: { try await sleeper.sleep($0) })
            .run(Self.url, from: 0))

        #expect(provider.received.count == 1)
        #expect(sleeper.durations.isEmpty)
        #expect(result.error is CancellationError)
    }

    /// `MacomprendoError.cancelled` is the provider's own "I was cancelled", so it is never
    /// retried either — one call, no sleep, and the error reaches the consumer.
    @Test func providerCancellationIsNotRetried() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)]])
        let provider = FakeTranscriptionProvider()
        provider.result = .failure(MacomprendoError.cancelled)
        let sleeper = SleepSpy()

        let result = await outcome(of: make(decoder: decoder, segmenter: segmenter,
                                            transcriber: { provider },
                                            sleep: { try await sleeper.sleep($0) })
            .run(Self.url, from: 0))

        #expect(provider.received.count == 1)
        #expect(sleeper.durations.isEmpty)
        #expect(result.error as? MacomprendoError == .cancelled)
    }

    /// Terminating the stream stops the work at the *next segment*, not the next chunk boundary:
    /// after the first of two segments in a chunk is in flight, termination must stop the second
    /// from ever reaching the provider.
    @Test @MainActor func terminatingTheStreamStopsTranscribing() async throws {
        let decoder = TerminatingDecoder(chunks: [Self.second(), Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [
            [Self.segment(at: 0), Self.segment(at: 1)],
            [Self.segment(at: 2)],
        ])
        let provider = FakeTranscriptionProvider()
        let gate = AsyncGate()
        provider.gate = gate

        let stream = LongAudioPipeline(decoder: decoder, segmenter: segmenter,
                                       transcriber: { provider }, language: "en")
            .run(Self.url, from: 0)

        let consumer = Task { () -> [LongAudioEvent] in
            var events: [LongAudioEvent] = []
            do { for try await event in stream { events.append(event) } } catch {}
            return events
        }

        // `.opened` is out; the first segment's transcription is now held at the gate.
        await waitFor("the first segment to reach the provider") { gate.waiterCount == 1 }
        consumer.cancel()
        let consumed = await consumer.value
        #expect(consumed.first == LongAudioEvent.opened(duration: 10))

        // Let the held transcription finish. The terminated stream must stop before the next
        // segment, so the provider never sees it — and the producing task must end (it drops the
        // decoder's stream), which is the deterministic point to assert from.
        gate.open()
        await waitFor("the producing task to stop pulling") { decoder.stopped.opened }

        #expect(provider.received.count == 1)
    }

    @Test func aDecoderOpenErrorIsThrownBeforeAnyEvent() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        decoder.openError = MacomprendoError.noAudioTrack
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)]])
        let provider = FakeTranscriptionProvider()

        let result = await outcome(of: make(decoder: decoder, segmenter: segmenter,
                                            transcriber: { provider })
            .run(Self.url, from: 0))

        #expect(result.events.isEmpty)
        #expect(result.error as? MacomprendoError == .noAudioTrack)
    }

    @Test func finishDrainsTheLastSegment() async throws {
        let decoder = ScriptedMediaDecoder(duration: 5, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [], finishSegments: [Self.segment(at: 2)])
        let provider = FakeTranscriptionProvider()

        let events = try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider })
                .run(Self.url, from: 0))

        #expect(events == [
            .opened(duration: 5),
            .position(1),
            .segment(start: 2, end: 3, text: "hello"),
        ])
    }
}
