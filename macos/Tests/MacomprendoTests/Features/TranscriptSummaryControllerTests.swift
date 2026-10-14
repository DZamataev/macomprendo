import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct TranscriptSummaryControllerTests {
    struct Rig {
        let controller: TranscriptSummaryController
        let store: FakeTranscriptStore
        let recorder: LLMCallRecorder
    }

    private func briefPreset() -> PromptPreset {
        PromptPreset(kind: .summarize, language: PromptLanguage.english.code,
                     name: "Brief", systemPrompt: "You are a summarizer.",
                     userTemplate: "Summarize the following:\n{text}",
                     isFactory: true, sortOrder: 0)
    }

    private func makeRig(deltas: [String] = ["Short", " summary"],
                         failure: MacomprendoError? = nil,
                         gate: AsyncGate? = nil,
                         pauseAfterDeltaCount: Int = 0,
                         partLimit: Int = TranscriptChunker.defaultLimit,
                         preset: (@MainActor () -> PromptPreset?)? = nil) -> Rig {
        let store = FakeTranscriptStore()
        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure, gate: gate,
                                           pauseAfterDeltaCount: pauseAfterDeltaCount,
                                           recorder: recorder)
        let resolvedPreset = preset ?? { self.briefPreset() }
        let controller = TranscriptSummaryController(
            store: store,
            llm: { LLMTarget(provider: provider, model: "qwen2.5:1.5b") },
            preset: resolvedPreset,
            language: { "English" },
            chosenLanguage: { "English" },
            partLimit: partLimit)
        return Rig(controller: controller, store: store, recorder: recorder)
    }

    /// Creates a transcript in the store — so `setSummary` has a row to write — and returns it.
    private func storedTranscript(in store: FakeTranscriptStore,
                                  segments: [TranscriptSegment],
                                  summary: String? = nil) async -> Transcript {
        let id = await store.create(sourceKind: .file, title: "lecture.mp3", sourceBookmark: nil,
                                    duration: 12,
                                    run: TranscriptionRun(modelID: "base", engine: "whisperCpp",
                                                          language: nil, appVersion: "1.0"),
                                    at: Date(timeIntervalSince1970: 0))
        for segment in segments { try? await store.appendSegment(segment, to: id) }
        if let summary { try? await store.setSummary(summary, for: id) }
        return try! await store.transcript(id: id)!
    }

    private func segment(_ text: String, start: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 1, text: text)
    }

    @Test func aShortTranscriptIsOneStreamedRequest() async {
        let rig = makeRig()
        let transcript = await storedTranscript(in: rig.store, segments: [segment("Hello world.")])
        rig.controller.show(transcript)

        rig.controller.summarize(transcript)
        await rig.controller.drain()

        #expect(rig.recorder.calls.count == 1)
        #expect(rig.controller.text == "Short summary")
        #expect(rig.controller.error == nil)
        #expect(!rig.controller.isRunning)
        #expect(rig.controller.progress == nil)
        let user = rig.recorder.calls.last?.messages.last?.content
        #expect(user?.contains("Summarize the following:") == true)
        #expect(user?.contains("Hello world.") == true)
        let stored = await rig.store.snapshot(transcript.id)?.summary
        #expect(stored == "Short summary")
    }

    @Test func aLongTranscriptIsMappedThenReduced() async {
        let gate = AsyncGate()
        let rig = makeRig(deltas: ["Part summary"], gate: gate, pauseAfterDeltaCount: 1,
                          partLimit: 5)
        let transcript = await storedTranscript(in: rig.store, segments: [
            segment("aaaa", start: 0), segment("bbbb", start: 1), segment("cccc", start: 2)])

        rig.controller.summarize(transcript)
        await waitFor("the first part to stream a delta") { gate.waiterCount == 1 }
        #expect(rig.controller.progress == "Summarizing part 1 of 3…")

        gate.open()
        await rig.controller.drain()

        #expect(rig.recorder.calls.count == 4)                      // 3 parts + 1 reduce
        #expect(rig.recorder.calls[0].messages.last?.content.contains("aaaa") == true)
        let reduceUser = rig.recorder.calls.last?.messages.last?.content
        #expect(reduceUser?.contains("Part summary\n\nPart summary\n\nPart summary") == true)
        #expect(rig.controller.text == "Part summary")
        #expect(rig.controller.progress == nil)
        let stored = await rig.store.snapshot(transcript.id)?.summary
        #expect(stored == "Part summary")
    }

    @Test func cancelKeepsThePreviousSummary() async {
        let gate = AsyncGate()
        let rig = makeRig(deltas: ["x", "y", "z"], gate: gate, pauseAfterDeltaCount: 1)
        let transcript = await storedTranscript(in: rig.store, segments: [segment("Hello.")],
                                                summary: "Old summary")
        rig.controller.show(transcript)
        #expect(rig.controller.text == "Old summary")

        rig.controller.summarize(transcript)
        await waitFor("the stream to suspend after the first delta") {
            gate.waiterCount == 1 && rig.controller.text == "x"
        }

        rig.controller.cancel()
        gate.open()
        await rig.controller.drain()

        #expect(rig.controller.text == "Old summary")
        #expect(!rig.controller.isRunning)
        #expect(rig.controller.error == nil)
        let stored = await rig.store.snapshot(transcript.id)?.summary
        #expect(stored == "Old summary")
    }

    @Test func aFailureSetsErrorAndKeepsThePreviousSummary() async {
        let rig = makeRig(deltas: ["x"], failure: .providerHTTP(status: 500, body: "boom"))
        let transcript = await storedTranscript(in: rig.store, segments: [segment("Hello.")],
                                                summary: "Old summary")
        rig.controller.show(transcript)

        rig.controller.summarize(transcript)
        await rig.controller.drain()

        #expect(rig.controller.error != nil)
        #expect(rig.controller.text == "Old summary")
        #expect(!rig.controller.isRunning)
        let stored = await rig.store.snapshot(transcript.id)?.summary
        #expect(stored == "Old summary")
    }

    @Test func noPresetIsAnError() async {
        let rig = makeRig(preset: { nil })
        let transcript = await storedTranscript(in: rig.store, segments: [segment("Hello.")])

        rig.controller.summarize(transcript)
        await rig.controller.drain()

        #expect(rig.controller.error == ErrorText.describe(FeatureConfigError.noPreset(.summarize)))
        #expect(!rig.controller.isRunning)
        #expect(rig.recorder.calls.isEmpty)
        let stored = await rig.store.snapshot(transcript.id)?.summary
        #expect(stored == nil)
    }
}
