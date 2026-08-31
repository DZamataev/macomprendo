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
        let audioRecorder: ScriptedRecorder
    }

    private func makeRig(deltas: [String] = ["Hello", " there"],
                         failure: MacomprendoError? = nil,
                         delayPerDelta: Duration = .zero,
                         configured: Bool = true,
                         mode: DictationMode = .hold,
                         holder: ScriptedSettingsHolder = .seeded()) -> Rig {
        holder.settings.dictationMode = mode
        let host = ScriptedPanelHost()
        let panel = QuickPanelController(holder: holder)
        panel.attach(host)

        let recorder = LLMCallRecorder()
        let provider = ScriptedLLMProvider(deltas: deltas, failure: failure,
                                           delayPerDelta: delayPerDelta, recorder: recorder)
        let pasteboard = ScriptedPasteboard()
        let inserter = ScriptedInserter()
        let toaster = ScriptedToaster()
        let audioRecorder = ScriptedRecorder()

        let capture = DictationCapture(
            recorder: audioRecorder,
            transcriberProvider: { ScriptedTranscriber(text: "spoken words") },
            permissions: ScriptedPermissions(),
            mode: { holder.settings.dictationMode },
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
            holder: holder)

        return Rig(controller: controller, panel: panel, host: host, pasteboard: pasteboard,
                   inserter: inserter, toaster: toaster, recorder: recorder, holder: holder,
                   audioRecorder: audioRecorder)
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
        #expect(rig.controller.selectedPresetID == FactoryPresets.presetID(role: .cleanUp, language: .english))
    }

    @Test func changingThePresetAndRerunningSendsANewRequest() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("raw text"))
        await rig.controller.drain()

        rig.controller.selectedPresetID = FactoryPresets.presetID(role: .shorten, language: .english)
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

    // In hold mode, show nothing while recording because
    // `HUDState.recording` renders "Release to transcribe · Esc cancels" and Esc is not
    // wired to `DictationCapture` — showing that hint here would be a false promise.
    @Test func holdDictationShowsNoHUDWhileRecordingAndTranscribingWhileTranscribing() async {
        let rig = makeRig(mode: .hold)
        rig.controller.handle(.keyDown(.dictateAndRefine))
        #expect(rig.toaster.states.isEmpty)
        #expect(rig.toaster.hideCount == 0)

        rig.controller.handle(.keyUp(.dictateAndRefine))
        #expect(rig.toaster.states == [.transcribing])

        await rig.controller.drainCapture()
        #expect(rig.toaster.hideCount == 1)      // back to idle just before the transcript arrives
        #expect(rig.panel.isVisible)             // ... and the Quick Panel takes over from there

        await rig.controller.drain()
    }

    @Test func toggleDictationShowsARecordingHUDUntilTheSecondPress() async {
        let rig = makeRig(mode: .toggle)
        let recording = HUDState.recordingPrompt(
            hint: "Press the hotkey again to transcribe."
        )

        rig.controller.handle(.keyDown(.dictateAndRefine))
        #expect(rig.toaster.states == [recording])

        rig.controller.handle(.keyUp(.dictateAndRefine))
        #expect(rig.toaster.states == [recording])

        rig.controller.handle(.keyDown(.dictateAndRefine))
        #expect(rig.toaster.states == [recording, .transcribing])

        await rig.controller.drainCapture()
        await rig.controller.drain()
    }

    @Test func aSilentDictationHidesTheTranscribingHUDAndToastsNothingHeard() async {
        let rig = makeRig()
        rig.audioRecorder.samples = []
        rig.controller.handle(.keyDown(.dictateAndRefine))
        rig.controller.handle(.keyUp(.dictateAndRefine))
        await rig.controller.drainCapture()

        #expect(rig.toaster.states == [.transcribing])
        #expect(rig.toaster.hideCount == 1)
        #expect(rig.toaster.messages.contains { $0.contains("Nothing heard") })
        #expect(!rig.panel.isVisible)
    }

    @Test func switchingLanguagePersistsItPicksTheNewDefaultAndReruns() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let rig = makeRig(holder: holder)
        rig.controller.start(source: .selection("hello"))
        await rig.controller.drain()
        let runsBefore = rig.recorder.calls.count

        rig.controller.promptLanguage = "ru"
        await rig.controller.drain()

        #expect(holder.settings.promptLanguage == "ru")
        #expect(rig.controller.selectedPresetID
                == FactoryPresets.presetID(role: .cleanUp, language: .russian))
        #expect(rig.recorder.calls.count > runsBefore)
        let sent = rig.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Приведи следующий текст в порядок") })
    }

    /// The panel keeps `selectedPresetID` between uses, so a language switched in Settings ▸
    /// Refine & Summarize has to be noticed the next time the panel opens — otherwise the
    /// stored English preset outlives the switch and the Picker shows a selection that is not
    /// in its own list.
    @Test func aLanguageSwitchedInSettingsReachesAnAlreadyUsedPanel() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let rig = makeRig(holder: holder)
        rig.controller.start(source: .selection("hello"))
        await rig.controller.drain()

        holder.settings.promptLanguage = "ru"      // Settings, behind the panel's back
        rig.controller.start(source: .selection("привет"))
        await rig.controller.drain()

        #expect(holder.settings.preset(id: rig.controller.selectedPresetID!)?.language == "ru")
        #expect(rig.controller.selectedPresetID
                == FactoryPresets.presetID(role: .cleanUp, language: .russian))
        let sent = rig.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Приведи следующий текст в порядок") })
    }

    /// The same staleness one layer down: even with the selection left alone, `runStream` must
    /// not accept a stored preset on `kind` alone.
    @Test func aStoredPresetFromAnotherLanguageIsNotUsedForTheRun() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "en"
        let rig = makeRig(holder: holder)
        rig.controller.selectedPresetID = FactoryPresets.presetID(role: .shorten,
                                                                  language: .english)
        holder.settings.promptLanguage = "ru"
        rig.controller.rerun()
        await rig.controller.drain()

        let sent = rig.recorder.calls.last!.messages
        #expect(sent.contains { $0.content.contains("Приведи следующий текст в порядок") })
    }

    /// The panel's preset menu writes through `selectPreset(_:)` rather than a raw binding plus
    /// `.onChange`, which also fired for the programmatic write a language switch makes and
    /// started a second, immediately cancelled stream.
    @Test func pickingThePresetThatIsAlreadySelectedDoesNotRerun() async {
        let rig = makeRig()
        rig.controller.start(source: .selection("hello"))
        await rig.controller.drain()
        let runs = rig.recorder.calls.count

        rig.controller.selectPreset(rig.controller.selectedPresetID)
        await rig.controller.drain()
        #expect(rig.recorder.calls.count == runs)

        rig.controller.selectPreset(FactoryPresets.presetID(role: .shorten, language: .english))
        await rig.controller.drain()
        #expect(rig.recorder.calls.count == runs + 1)
    }

    @Test func settingTheSameLanguageDoesNotRerun() async {
        let holder = ScriptedSettingsHolder.seeded()
        holder.settings.promptLanguage = "ru"
        let rig = makeRig(holder: holder)
        rig.controller.start(source: .selection("привет"))
        await rig.controller.drain()
        let runs = rig.recorder.calls.count
        rig.controller.promptLanguage = "ru"
        await rig.controller.drain()
        #expect(rig.recorder.calls.count == runs)
    }
}
