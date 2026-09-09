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
                         delayPerDelta: Duration = .zero,
                         gate: AsyncGate? = nil,
                         pauseAfterDeltaCount: Int = 0,
                         holder: ScriptedSettingsHolder = .seeded()) -> Rig {
        let panel = QuickPanelController(holder: holder)
        panel.attach(ScriptedPanelHost())

        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure,
                                           delayPerDelta: delayPerDelta, gate: gate,
                                           pauseAfterDeltaCount: pauseAfterDeltaCount,
                                           recorder: recorder)
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
            holder: holder)

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

    /// Uses an `AsyncGate` rather than a fixed sleep so the cancel lands deterministically
    /// between the first and second delta. The `Task.sleep(60ms)` this replaced raced
    /// `delayPerDelta: 40ms`: on a loaded CI runner all three deltas streamed before `stop()`
    /// fired and the partial-summary assertion failed. See `RefineControllerTests`, which hit
    /// the same flake first.
    @Test func stopKeepsThePartialSummary() async {
        let gate = AsyncGate()
        let rig = makeRig(deltas: ["x", "y", "z"], gate: gate, pauseAfterDeltaCount: 1)
        rig.controller.start(text: "text")
        await waitFor("the stream to suspend after the first delta") {
            gate.waiterCount == 1 && rig.controller.summary == "x"
        }

        rig.controller.stop()
        gate.open()
        await rig.controller.drain()

        #expect(!rig.controller.isStreaming)
        #expect(rig.controller.summary == "x")   // no further delta after the cancel
        #expect(rig.controller.error == nil)     // cancellation is not an error
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

    @Test func switchingLanguagePersistsItPicksTheNewDefaultAndReruns() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let rig = makeRig(holder: holder)
        rig.controller.start(text: "hello")
        await rig.controller.drain()
        let runsBefore = rig.recorder.calls.count

        rig.controller.promptLanguage = "ru"
        await rig.controller.drain()

        #expect(holder.settings.promptLanguage == "ru")
        #expect(rig.controller.selectedPresetID
                == FactoryPresets.presetID(role: .brief, language: .russian))
        #expect(rig.recorder.calls.count > runsBefore)
        let sent = rig.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Изложи следующий текст в двух-трёх предложениях") })
    }

    /// See `RefineControllerTests`: the panel keeps `selectedPresetID` between uses, so a
    /// language switched in Settings has to reach it the next time it opens.
    @Test func aLanguageSwitchedInSettingsReachesAnAlreadyUsedPanel() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let rig = makeRig(holder: holder)
        rig.controller.start(text: "an article")
        await rig.controller.drain()

        holder.settings.promptLanguage = "ru"      // Settings, behind the panel's back
        rig.controller.start(text: "статья")
        await rig.controller.drain()

        #expect(holder.settings.preset(id: rig.controller.selectedPresetID!)?.language == "ru")
        #expect(rig.controller.selectedPresetID
                == FactoryPresets.presetID(role: .brief, language: .russian))
        let sent = rig.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Изложи следующий текст") })
    }

    @Test func aStoredPresetFromAnotherLanguageIsNotUsedForTheRun() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let rig = makeRig(holder: holder)
        rig.controller.selectedPresetID = FactoryPresets.presetID(role: .bullets,
                                                                  language: .english)
        holder.settings.promptLanguage = "ru"
        rig.controller.rerun()
        await rig.controller.drain()

        let sent = rig.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Изложи следующий текст") })
    }

    @Test func pickingThePresetThatIsAlreadySelectedDoesNotRerun() async {
        let rig = makeRig()
        rig.controller.start(text: "an article")
        await rig.controller.drain()
        let runs = rig.recorder.calls.count

        rig.controller.selectPreset(rig.controller.selectedPresetID)
        await rig.controller.drain()
        #expect(rig.recorder.calls.count == runs)

        rig.controller.selectPreset(FactoryPresets.presetID(role: .bullets, language: .english))
        await rig.controller.drain()
        #expect(rig.recorder.calls.count == runs + 1)
    }

    @Test func settingTheSameLanguageDoesNotRerun() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "ru"
        let rig = makeRig(holder: holder)
        rig.controller.start(text: "привет")
        await rig.controller.drain()
        let runs = rig.recorder.calls.count
        rig.controller.promptLanguage = "ru"
        await rig.controller.drain()
        #expect(rig.recorder.calls.count == runs)
    }
}
