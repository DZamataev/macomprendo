import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct RefineControllerTests {
    struct Rig {
        let controller: RefineController
        let panel: QuickPanelController
        let host: ScriptedPanelHost
        let pasteboard: ScriptedPasteboard
        let inserter: ScriptedInserter
        let toaster: ScriptedToaster
        let recorder: LLMCallRecorder
        let holder: ScriptedSettingsHolder
    }

    private func makeRig(deltas: [String] = ["Hello", " there"],
                         failure: MacomprendoError? = nil,
                         delayPerDelta: Duration = .zero,
                         configured: Bool = true) -> Rig {
        let holder = ScriptedSettingsHolder.seeded()
        let host = ScriptedPanelHost()
        let panel = QuickPanelController(holder: holder)
        panel.attach(host)

        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure,
                                           delayPerDelta: delayPerDelta, recorder: recorder)
        let pasteboard = ScriptedPasteboard()
        let inserter = ScriptedInserter()
        let toaster = ScriptedToaster()

        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "spoken words") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { "en" })

        let controller = RefineController(
            capture: capture,
            llm: {
                guard configured else { throw FeatureConfigError.llmNotConfigured(.refine) }
                return LLMTarget(provider: provider, model: "qwen2.5:1.5b")
            },
            panel: panel,
            pasteboard: pasteboard,
            inserter: inserter,
            tracker: ScriptedTracker(),
            toaster: toaster,
            settings: { holder.settings })

        return Rig(controller: controller, panel: panel, host: host, pasteboard: pasteboard,
                   inserter: inserter, toaster: toaster, recorder: recorder, holder: holder)
    }

    @Test func startingFromASelectionOpensThePanelAndStreamsTheResult() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("  raw text  "))
        #expect(rig.controller.original == "raw text")
        #expect(rig.panel.isVisible)
        #expect(rig.panel.layout == .refine)
        #expect(rig.controller.isStreaming)

        await rig.controller.drain()

        #expect(rig.controller.refined == "Hello there")
        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.error == nil)
    }

    @Test func theRenderedPromptUsesTheDefaultPresetAndTheInstruction() async {
        let rig = makeRig()
        rig.controller.instruction = "keep it short"
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        let call = rig.recorder.calls.last
        #expect(call?.model == "qwen2.5:1.5b")
        #expect(call?.messages.first?.role == .system)
        #expect(call?.messages.last?.content.contains("keep it short") == true)
        #expect(call?.messages.last?.content.contains("raw text") == true)
        #expect(rig.controller.selectedPresetID == FactoryPresets.ID.cleanUp)
    }

    @Test func changingThePresetAndRerunningSendsANewRequest() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        rig.controller.selectedPresetID = FactoryPresets.ID.shorten
        rig.controller.instruction = "two sentences"
        rig.controller.rerun()
        await rig.controller.drain()

        #expect(rig.recorder.calls.count == 2)
        #expect(rig.recorder.calls[1].messages.last?.content.contains("significantly shorter") == true)
        #expect(rig.recorder.calls[1].messages.last?.content.contains("two sentences") == true)
        #expect(rig.controller.refined == "Hello there")     // reset then refilled
    }

    @Test func providerFailureShowsAnErrorBanner() async {
        let rig = makeRig(deltas: [], failure: .providerUnreachable(endpointName: "Ollama (local)"))
        rig.controller.start(source: .selection("raw"))
        await rig.controller.drain()

        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.error?.contains(
            MacomprendoError.providerUnreachable(endpointName: "Ollama (local)").errorDescription ?? "!") == true)
    }

    @Test func aMissingLLMConfigurationIsReportedInTheBanner() async {
        let rig = makeRig(configured: false)
        rig.controller.start(source: .selection("raw"))
        await rig.controller.drain()
        #expect(rig.controller.error?.contains("Refine") == true)
        #expect(!rig.controller.isStreaming)
    }

    @Test func stopCancelsTheStreamAndKeepsThePartialText() async {
        let rig = makeRig(deltas: ["a", "b", "c"], delayPerDelta: .milliseconds(40))
        rig.controller.start(source: .selection("raw"))
        try? await Task.sleep(for: .milliseconds(60))
        rig.controller.stop()
        await rig.controller.drain()

        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.refined.count < 3)
        #expect(rig.controller.error == nil)            // cancellation is not an error
    }

    @Test func copyPutsTheChosenSideOnThePasteboardAndKeepsThePanelOpen() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        rig.controller.copy(.original)
        #expect(rig.pasteboard.readString() == "raw text")
        rig.controller.copy(.refined)
        #expect(rig.pasteboard.readString() == "Hello there")
        #expect(rig.toaster.messages.count == 2)
        #expect(rig.panel.isVisible)
    }

    @Test func insertPastesIntoTheRememberedAppAndClosesThePanel() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        await rig.controller.insert(.refined)

        #expect(rig.inserter.calls == [ScriptedInserter.Call(
            text: "Hello there",
            app: FrontmostApp(pid: 42, bundleID: "com.example.editor", name: "Editor"),
            method: Settings.default.insertMethod)])
        #expect(!rig.panel.isVisible)
    }

    @Test func aFailedInsertToastsAndLeavesThePanelOpen() async {
        let rig = makeRig()
        rig.inserter.failure = .insertFailed
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        await rig.controller.insert(.original)

        #expect(rig.toaster.messages.count == 1)
        #expect(rig.panel.isVisible)
    }

    @Test func dictationSourceFillsOriginalFromTheTranscript() async {
        let rig = makeRig()
        rig.controller.handle(.keyDown(.dictateAndRefine))
        rig.controller.handle(.keyUp(.dictateAndRefine))
        await rig.controller.drainCapture()
        await rig.controller.drain()

        #expect(rig.controller.original == "spoken words")
        #expect(rig.panel.isVisible)
        #expect(rig.controller.refined == "Hello there")
    }
}
