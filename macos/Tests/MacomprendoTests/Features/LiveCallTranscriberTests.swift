import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct LiveCallTranscriberTests {
    private static let sessionStart: TimeInterval = 1_000
    private static let oneSecond = [Float](repeating: 0.5,
                                           count: Int(AssetCallTrackWriter.sampleRate))

    /// One fresh pipeline per call, each with its own segmenter that turns its first chunk into
    /// one segment at 0, and the provider at the same index.
    private func pipelines(_ providers: [FakeTranscriptionProvider])
        -> @MainActor () -> LongAudioPipeline {
        let next = Box(0)
        return {
            let provider = providers[next.value]
            next.value += 1
            let segment = SpeechSegment(start: 0,
                                        samples: [Float](repeating: 0.1,
                                                         count: AVAssetMediaDecoder.sampleRate),
                                        sampleRate: AVAssetMediaDecoder.sampleRate)
            return LongAudioPipeline(decoder: ScriptedMediaDecoder(),
                                     segmenter: ScriptedSegmenter(acceptScript: [[segment]]),
                                     transcriber: { provider }, language: nil)
        }
    }

    private func makeRow(_ store: FakeTranscriptStore) async throws -> Int64 {
        try await store.create(sourceKind: .call, title: "Call", sourceBookmark: nil,
                               duration: nil, run: TranscriptionRun.from(
                                   Settings.default.transcriptionSource, language: nil),
                               at: .now)
    }

    @Test func segmentsFromBothTracksLandWithSpeakerAndTheirTracksOffset() async throws {
        let store = FakeTranscriptStore()
        let id = try await makeRow(store)
        let changes = Box(0)
        let live = LiveCallTranscriber(
            transcriptID: id, store: store,
            pipeline: pipelines([FakeTranscriptionProvider(), FakeTranscriptionProvider()]),
            settings: .default, glossary: Glossary(),
            transcriptsChanged: { changes.value += 1 })
        let me = LiveTrackFeed(sessionStart: Self.sessionStart)
        let others = LiveTrackFeed(sessionStart: Self.sessionStart)
        live.start(me, speaker: .me)
        live.start(others, speaker: .others)

        me.consume(Self.oneSecond, at: Self.sessionStart + 0.25)
        others.consume(Self.oneSecond, at: Self.sessionStart + 0.5)
        // `waitFor` polls synchronously; `transcriptsChanged` fires after each append lands.
        await waitFor("both tracks' segments to be stored") { changes.value == 2 }
        await live.stop()

        let segments = try #require(await store.snapshot(id)?.segments)
        #expect(Set(segments.map(\.speaker)) == [.me, .others])
        #expect(segments.first { $0.speaker == .me }?.start == 0.25)
        #expect(segments.first { $0.speaker == .others }?.start == 0.5)
        #expect(changes.value == 2)
    }

    @Test func aFailingTrackLeavesTheOtherRunning() async throws {
        let store = FakeTranscriptStore()
        let id = try await makeRow(store)
        let failing = FakeTranscriptionProvider()
        failing.result = .failure(MacomprendoError.transcriptStore("boom"))
        let changes = Box(0)
        let live = LiveCallTranscriber(
            transcriptID: id, store: store,
            pipeline: pipelines([failing, FakeTranscriptionProvider()]),
            settings: .default, glossary: Glossary(),
            transcriptsChanged: { changes.value += 1 })
        let me = LiveTrackFeed(sessionStart: Self.sessionStart)
        let others = LiveTrackFeed(sessionStart: Self.sessionStart)
        live.start(me, speaker: .me)
        live.start(others, speaker: .others)

        me.consume(Self.oneSecond, at: Self.sessionStart)
        others.consume(Self.oneSecond, at: Self.sessionStart)
        await waitFor("the Others segment to be stored") { changes.value == 1 }
        await live.stop()
        #expect(await store.snapshot(id)?.segments.map(\.speaker) == [.others])
    }

    @Test func stopReturnsWithTheFeedsStillOpenAndNothingIsAppendedAfter() async throws {
        let store = FakeTranscriptStore()
        let id = try await makeRow(store)
        let provider = FakeTranscriptionProvider()
        let gate = AsyncGate()
        provider.gate = gate
        let live = LiveCallTranscriber(
            transcriptID: id, store: store, pipeline: pipelines([provider]),
            settings: .default, glossary: Glossary(), transcriptsChanged: {})
        let me = LiveTrackFeed(sessionStart: Self.sessionStart)
        live.start(me, speaker: .me)
        me.consume(Self.oneSecond, at: Self.sessionStart)
        await waitFor("the segment to reach the provider") { provider.received.count == 1 }

        let stopped = Task { await live.stop() }
        gate.open()
        await stopped.value

        #expect(await store.snapshot(id)?.segments.isEmpty == true)
    }
}
