import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct TextFeaturesTests {
    struct Rig {
        let features: TextFeatures
        let speech: ScriptedSpeech
        let toaster: ScriptedToaster
        let panelHost: ScriptedPanelHost
        let keys: ScriptedKeySimulator
    }

    private func makeRig(selection: String?) -> Rig {
        let holder = ScriptedSettingsHolder.seeded()
        let host = ScriptedPanelHost()
        let panel = QuickPanelController(holder: holder)
        panel.attach(host)

        let provider = ScriptedLLMProvider(deltas: ["ok"], recorder: LLMCallRecorder())
        let pasteboard = ScriptedPasteboard(initialString: "clip")
        let keys = ScriptedKeySimulator()
        let toaster = ScriptedToaster()
        let speech = ScriptedSpeech()

        let capture = DictationCapture(
            recorder: ScriptedRecorder(),
            transcriberProvider: { ScriptedTranscriber(text: "spoken") },
            permissions: ScriptedPermissions(),
            mode: { .hold },
            language: { nil })

        let refine = RefineController(
            capture: capture,
            llm: { LLMTarget(provider: provider, model: "m") },
            panel: panel, pasteboard: pasteboard, inserter: ScriptedInserter(),
            tracker: ScriptedTracker(), toaster: toaster, settings: { holder.settings })

        let summarize = SummarizeController(
            llm: { LLMTarget(provider: provider, model: "m") },
            panel: panel, pasteboard: pasteboard, inserter: ScriptedInserter(),
            tracker: ScriptedTracker(), toaster: toaster, settings: { holder.settings })

        let speak = SpeakController(speech: speech, toaster: toaster, settings: { holder.settings })

        let selectedText = AXSelectedTextService(
            ax: ScriptedAXReader(text: selection), pasteboard: pasteboard,
            keySimulator: keys, copyTimeout: 0.02, pollInterval: 0.005)

        let features = TextFeatures(quickPanel: panel, refine: refine, summarize: summarize,
                                    speak: speak, selectedText: selectedText, toaster: toaster)
        return Rig(features: features, speech: speech, toaster: toaster, panelHost: host, keys: keys)
    }

    @Test func summarizeHotkeyReadsTheSelectionAndOpensTheSummaryPanel() async {
        let rig = makeRig(selection: "an article")
        rig.features.handle(.keyDown(.summarize))
        await rig.features.drain()
        await rig.features.summarize.drain()

        #expect(rig.features.summarize.source == "an article")
        #expect(rig.features.quickPanel.layout == .summary)
        #expect(rig.features.quickPanel.isVisible)
    }

    @Test func refineSelectionHotkeyOpensTheRefinePanel() async {
        let rig = makeRig(selection: "some prose")
        rig.features.handle(.keyDown(.refineSelection))
        await rig.features.drain()
        await rig.features.refine.drain()

        #expect(rig.features.refine.original == "some prose")
        #expect(rig.features.quickPanel.layout == .refine)
    }

    @Test func speakHotkeySpeaksTheSelectionAndTheSecondPressStops() async {
        let rig = makeRig(selection: "read this")
        rig.features.handle(.keyDown(.speak))
        await rig.features.drain()
        #expect(rig.speech.spoken.map(\.text) == ["read this"])

        rig.features.handle(.keyDown(.speak))
        await rig.features.drain()
        #expect(rig.speech.stopCount == 1)
        #expect(rig.speech.spoken.count == 1)
    }

    @Test func anEmptySelectionToastsAndOpensNothing() async {
        let rig = makeRig(selection: nil)          // no AX text, no ⌘C result either
        rig.features.handle(.keyDown(.summarize))
        await rig.features.drain()

        #expect(rig.toaster.messages.count == 1)
        #expect(rig.toaster.messages[0].contains(MacomprendoError.noSelection.errorDescription ?? "!"))
        #expect(!rig.features.quickPanel.isVisible)
    }

    @Test func dictateAndRefineIsRoutedToTheRefineControllerAsHoldAndRelease() async {
        let rig = makeRig(selection: nil)
        rig.features.handle(.keyDown(.dictateAndRefine))
        rig.features.handle(.keyUp(.dictateAndRefine))
        await rig.features.refine.drainCapture()
        await rig.features.refine.drain()

        #expect(rig.features.refine.original == "spoken")
        #expect(rig.features.quickPanel.isVisible)
        #expect(rig.keys.presses.isEmpty)          // the microphone path never touches the clipboard
    }

    @Test func plainDictateHotkeyIsIgnoredHere() async {
        let rig = makeRig(selection: "text")
        rig.features.handle(.keyDown(.dictate))
        rig.features.handle(.keyUp(.dictate))
        await rig.features.drain()
        #expect(!rig.features.quickPanel.isVisible)
        #expect(rig.speech.spoken.isEmpty)
    }
}
