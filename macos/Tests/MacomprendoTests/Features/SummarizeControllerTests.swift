import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SummarizeControllerTests {
    struct Rig {
        let controller: SummarizeController
        let panel: QuickPanelController
        let pasteboard: ScriptedPasteboard
        let inserter: ScriptedInserter
        let toaster: ScriptedToaster
        let recorder: LLMCallRecorder
        let holder: ScriptedSettingsHolder
    }

    private func makeRig(deltas: [String] = ["Short", " summary"],
                         failure: MacomprendoError? = nil,
                         delayPerDelta: Duration = .zero) -> Rig {
        let holder = ScriptedSettingsHolder.seeded()
        let panel = QuickPanelController(holder: holder)
        panel.attach(ScriptedPanelHost())

        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure,
                                           delayPerDelta: delayPerDelta, recorder: recorder)
        let pasteboard = ScriptedPasteboard()
        let inserter = ScriptedInserter()
        let toaster = ScriptedToaster()

        let controller = SummarizeController(
            llm: { LLMTarget(provider: provider, model: "qwen2.5:1.5b") },
            panel: panel,
            pasteboard: pasteboard,
            inserter: inserter,
            tracker: ScriptedTracker(),
            toaster: toaster,
            settings: { holder.settings })

        return Rig(controller: controller, panel: panel, pasteboard: pasteboard,
                   inserter: inserter, toaster: toaster, recorder: recorder, holder: holder)
    }

    @Test func startOpensTheSummaryLayoutAndStreams() async {
        let rig = makeRig()
        rig.controller.start(text: "  a long article  ")
        #expect(rig.controller.source == "a long article")
        #expect(rig.panel.isVisible)
        #expect(rig.panel.layout == .summary)

        await rig.controller.drain()

        #expect(rig.controller.summary == "Short summary")
        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.selectedPresetID == FactoryPresets.presetID(role: .brief, language: .english))
    }

    @Test func theBriefPresetTemplateIsUsed() async {
        let rig = makeRig()
        rig.controller.start(text: "a long article")
        await rig.controller.drain()
        let user = rig.recorder.calls.last?.messages.last?.content
        #expect(user?.contains("two or three sentences") == true)
        #expect(user?.contains("a long article") == true)
    }

    @Test func switchingToBulletsAndRerunningResends() async {
        let rig = makeRig()
        rig.controller.start(text: "a long article")
        await rig.controller.drain()

        rig.controller.selectedPresetID = FactoryPresets.presetID(role: .bullets, language: .english)
        rig.controller.rerun()
        await rig.controller.drain()

        #expect(rig.recorder.calls.count == 2)
        #expect(rig.recorder.calls[1].messages.last?.content.contains("bullet points") == true)
    }

    @Test func providerFailureIsShownInTheBanner() async {
        let rig = makeRig(deltas: [], failure: .providerHTTP(status: 500, body: "boom"))
        rig.controller.start(text: "text")
        await rig.controller.drain()
        #expect(rig.controller.error != nil)
        #expect(!rig.controller.isStreaming)
    }

    @Test func stopKeepsThePartialSummary() async {
        let rig = makeRig(deltas: ["x", "y", "z"], delayPerDelta: .milliseconds(40))
        rig.controller.start(text: "text")
        try? await Task.sleep(for: .milliseconds(60))
        rig.controller.stop()
        await rig.controller.drain()
        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.summary.count < 3)
        #expect(rig.controller.error == nil)
    }

    @Test func copyWritesTheSummaryAndKeepsThePanelOpen() async {
        let rig = makeRig()
        rig.controller.start(text: "text")
        await rig.controller.drain()
        rig.controller.copy()
        #expect(rig.pasteboard.readString() == "Short summary")
        #expect(rig.toaster.messages.count == 1)
        #expect(rig.panel.isVisible)
    }

    @Test func replaceSelectionPastesTheSummaryAndClosesThePanel() async {
        let rig = makeRig()
        rig.controller.start(text: "text")
        await rig.controller.drain()

        await rig.controller.replaceSelection()

        #expect(rig.inserter.calls.count == 1)
        #expect(rig.inserter.calls[0].text == "Short summary")
        #expect(rig.inserter.calls[0].app?.name == "Editor")
        #expect(!rig.panel.isVisible)
    }

    @Test func replaceSelectionBeforeAnySummaryToastsInstead() async {
        let rig = makeRig(deltas: [], delayPerDelta: .milliseconds(200))
        rig.controller.start(text: "text")
        await rig.controller.replaceSelection()
        #expect(rig.inserter.calls.isEmpty)
        #expect(rig.toaster.messages.count == 1)
        rig.controller.stop()
    }
}
