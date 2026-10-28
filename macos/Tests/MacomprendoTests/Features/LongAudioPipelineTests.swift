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
                      speechPresence: (any SpeechPresenceMeasuring)? = nil,
                      retryDelay: Duration = .seconds(1),
                      sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in })
        -> LongAudioPipeline {
        LongAudioPipeline(decoder: decoder, segmenter: segmenter, transcriber: transcriber,
                          language: language, speechPresence: speechPresence,
                          retryDelay: retryDelay, sleep: sleep)
    }

    /// A provider that detects a scripted language per call, as whisper.cpp does with `auto`,
    /// and records the language each call was asked for.
    private final class DetectingProvider: TranscriptionProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [RecognisedSpeech]
        private var _asked: [String?] = []
        init(_ script: [RecognisedSpeech]) { self.script = script }
        var asked: [String?] { lock.withLock { _asked } }

        func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
            try await recognise(pcm, sampleRate: sampleRate, language: language).text
        }

        func recognise(_ pcm: [Float], sampleRate: Int, language: String?) async throws
            -> RecognisedSpeech {
            lock.withLock {
                _asked.append(language)
                return script.isEmpty ? RecognisedSpeech(text: "", language: nil)
                                      : script.removeFirst()
            }
        }
    }

    private static func said(_ text: String, _ language: String?) -> RecognisedSpeech {
        RecognisedSpeech(text: text, language: language)
    }

    /// Segments one second apart, `seconds` long each, all from one `accept`.
    private func gated(_ provider: DetectingProvider, presence: ScriptedSpeechPresence,
                       count: Int, language: String? = nil, seconds: TimeInterval = 1)
        async throws -> [LongAudioEvent] {
        let samples = [Float](repeating: 0.1, count: Int(seconds * 16_000))
        let segments = (0..<count).map {
            SpeechSegment(start: TimeInterval($0) * 10, samples: samples, sampleRate: 16_000)
        }
        let decoder = ScriptedMediaDecoder(duration: 60, chunks: [Self.second()])
        let segmenter = ScriptedSegmenter(acceptScript: [segments])
        return try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider },
                 language: language, speechPresence: presence).run(Self.url, from: 0))
    }

    private func texts(_ events: [LongAudioEvent]) -> [String] {
        events.compactMap { if case let .segment(_, _, text) = $0 { text } else { nil } }
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

    // MARK: - Phantom gate

    @Test func aPhantomInAnotherLanguageOverSilenceIsNotEmitted() async throws {
        let provider = DetectingProvider([Self.said("Привет всем.", "ru"),
                                          Self.said("*Sigh*", "en"),
                                          Self.said("Пока.", "ru")])
        let presence = ScriptedSpeechPresence([0.7, 0])
        let events = try await gated(provider, presence: presence, count: 3)
        #expect(texts(events) == ["Привет всем.", "Пока."])
        // The first segment, before any language was known, and the mismatch; a segment in the
        // transcript's language is never measured.
        #expect(presence.measured == 2)
    }

    @Test func shortSpeechInAWrongLanguageIsDecodedAgainInTheTranscriptsLanguage() async throws {
        let provider = DetectingProvider([Self.said("Привет.", "ru"),
                                          Self.said("On sobie nie nienka.", "pl"),
                                          Self.said("Он сегодня нянька.", "ru")])
        let events = try await gated(provider, presence: ScriptedSpeechPresence([0.7, 0.55]),
                                     count: 2)
        #expect(texts(events) == ["Привет.", "Он сегодня нянька."])
        #expect(provider.asked == [nil, nil, "ru"])
    }

    @Test func aRedecodeThatHearsNothingDropsTheSegment() async throws {
        let provider = DetectingProvider([Self.said("Привет.", "ru"), Self.said("Mm.", "en"),
                                          Self.said("", "ru")])
        let events = try await gated(provider, presence: ScriptedSpeechPresence([0.7, 0.3]),
                                     count: 2)
        #expect(texts(events) == ["Привет."])
    }

    @Test func aLongStretchInAnotherLanguageIsKept() async throws {
        let provider = DetectingProvider([Self.said("Привет.", "ru"),
                                          Self.said("Let me say this in English.", "en")])
        let events = try await gated(provider, presence: ScriptedSpeechPresence([0.7, 0.8]), count: 2,
                                     seconds: 6)
        #expect(texts(events) == ["Привет.", "Let me say this in English."])
        #expect(provider.asked == [nil, nil])
    }

    @Test func aPhantomBeforeAnyLanguageIsKnownIsDroppedOnlyOverSilence() async throws {
        let provider = DetectingProvider([Self.said("you", "en"), Self.said("Привет.", "ru")])
        let events = try await gated(provider, presence: ScriptedSpeechPresence([0, 0.7]),
                                     count: 2)
        #expect(texts(events) == ["Привет."])
    }

    @Test func aRunWithAChosenLanguageIsNeverGated() async throws {
        let provider = DetectingProvider([Self.said("Hi.", "en"), Self.said("*Sigh*", "de")])
        let presence = ScriptedSpeechPresence([0])
        let events = try await gated(provider, presence: presence, count: 2, language: "en")
        #expect(texts(events) == ["Hi.", "*Sigh*"])
        #expect(presence.measured == 0)
    }

    @Test func aProviderThatReportsNoLanguageIsNeverGated() async throws {
        let provider = DetectingProvider([Self.said("one", nil), Self.said("two", nil)])
        let presence = ScriptedSpeechPresence([0])
        let events = try await gated(provider, presence: presence, count: 2)
        #expect(texts(events) == ["one", "two"])
        #expect(presence.measured == 0)
    }

    // MARK: - Tests

    @Test func anAlreadyOpenStreamRunsLikeAFileWithoutTheDecoder() async throws {
        let decoder = ScriptedMediaDecoder()
        let segmenter = ScriptedSegmenter(acceptScript: [[Self.segment(at: 0)], [Self.segment(at: 1)]])
        let provider = FakeTranscriptionProvider()
        let chunks = AsyncThrowingStream<[Float], Error> { continuation in
            continuation.yield(Self.second())
            continuation.yield(Self.second())
            continuation.finish()
        }

        let events = try await collect(
            make(decoder: decoder, segmenter: segmenter, transcriber: { provider })
                .run(DecodedAudio(duration: 0, startOffset: 0, chunks: chunks)))

        #expect(events == [
            .opened(duration: 0),
            .segment(start: 0, end: 1, text: "hello"),
            .position(1),
            .segment(start: 1, end: 2, text: "hello"),
            .position(2),
        ])
        #expect(decoder.requests.isEmpty)
    }

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
