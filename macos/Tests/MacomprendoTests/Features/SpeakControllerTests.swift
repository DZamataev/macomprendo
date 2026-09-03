import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct SpeakControllerTests {
    private func make(_ speechSettings: SpeechSettings = SpeechSettings(voiceID: "com.apple.voice.x",
                                                                        rate: 0.6, pitch: 1.1, volume: 0.9))
        -> (SpeakController, ScriptedSpeech, ScriptedToaster) {
        let speech = ScriptedSpeech()
        let toaster = ScriptedToaster()
        var settings = Settings.default
        settings.speech = speechSettings
        let controller = SpeakController(speech: speech, toaster: toaster, settings: { settings })
        return (controller, speech, toaster)
    }

    @Test func speaksTheSuppliedTextWithTheConfiguredVoice() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "  read me  " })
        #expect(speech.spoken.count == 1)
        #expect(speech.spoken[0].text == "read me")
        #expect(speech.spoken[0].settings.voiceID == "com.apple.voice.x")
        #expect(speech.spoken[0].settings.rate == 0.6)
        #expect(controller.isSpeaking)
        #expect(toaster.messages.isEmpty)
    }

    @Test func togglingWhileSpeakingStops() async {
        let (controller, speech, _) = make()
        await controller.toggle(text: { "first" })
        await controller.toggle(text: { Issue.record("must not read again"); return "" })
        #expect(speech.stopCount == 1)
        #expect(speech.spoken.count == 1)
        #expect(!controller.isSpeaking)
    }

    @Test func noSelectionErrorBecomesAToast() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { throw MacomprendoError.noSelection })
        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages.count == 1)
        #expect(toaster.messages[0].contains(MacomprendoError.noSelection.errorDescription ?? "!"))
    }

    @Test func blankTextIsReportedAsNoSelection() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "   \n" })
        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages.count == 1)
    }

    /// Dismissing the panel — with Esc, or as part of Insert / Replace selection — is a "done
    /// here" gesture. A panel-initiated read has no controls left once the panel is gone and
    /// deliberately shows no HUD, so it stops with the panel.
    @Test func dismissingThePanelStopsAReadThePanelStarted() {
        let (controller, speech, _) = make()
        controller.speak("refined text", from: .refineRefined)
        #expect(controller.isSpeaking)

        controller.stopPanelPlayback()

        #expect(speech.stopCount == 1)
        #expect(!controller.isSpeaking)
        #expect(controller.active == nil)
    }

    /// A hotkey read that merely overlaps the panel owns the HUD and ⌥S, so it is left alone.
    @Test func dismissingThePanelLeavesAHotkeyReadAlone() async {
        let (controller, speech, _) = make()
        await controller.toggle(text: { "selection" })
        #expect(controller.active == .hotkey)

        controller.stopPanelPlayback()

        #expect(speech.stopCount == 0)
        #expect(controller.isSpeaking)
        #expect(controller.active == .hotkey)
    }

    @Test func dismissingThePanelWhileNothingPlaysIsANoOp() {
        let (controller, speech, _) = make()
        controller.stopPanelPlayback()
        #expect(speech.stopCount == 0)
    }

    @Test func finishingNaturallyClearsTheSpeakingFlag() async {
        let (controller, speech, _) = make()
        await controller.toggle(text: { "hello" })
        #expect(controller.isSpeaking)
        speech.finish()
        #expect(!controller.isSpeaking)
    }

    @Test func startingPlaybackShowsTheSpeakingHUDWithTheStopHint() async {
        let (controller, _, toaster) = make()
        await controller.toggle(text: { "read me" })
        #expect(toaster.states == [.speaking(hint: SpeakController.stopHint)])
        #expect(SpeakController.stopHint.contains("stop"))
        #expect(toaster.hideCount == 0)
    }

    @Test func finishingNaturallyHidesTheSpeakingHUD() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "read me" })
        speech.finish()
        #expect(toaster.hideCount == 1)
        #expect(!controller.isSpeaking)
    }

    @Test func togglingWhileSpeakingHidesTheSpeakingHUD() async {
        let (controller, _, toaster) = make()
        await controller.toggle(text: { "read me" })
        await controller.toggle(text: { Issue.record("must not read again"); return "" })
        #expect(toaster.hideCount == 1)
        #expect(toaster.states.count == 1)          // no second .speaking
    }

    @Test func aBackendErrorHidesTheHUDAndThenToasts() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "read me" })
        #expect(toaster.states.count == 1)

        speech.failWith(MacomprendoError.providerHTTP(status: 401, body: "bad key"))

        #expect(!controller.isSpeaking)
        #expect(toaster.hideCount == 1)
        #expect(toaster.messages.count == 1)
        #expect(toaster.messages[0].contains("401"))
    }

    @Test func theBackendErrorToastCarriesTheRecoverySuggestion() async {
        let (controller, speech, toaster) = make()
        await controller.toggle(text: { "read me" })
        speech.failWith(MacomprendoError.providerUnreachable(endpointName: "api.openai.com"))

        let expected = ErrorText.describe(
            MacomprendoError.providerUnreachable(endpointName: "api.openai.com"))
        #expect(toaster.messages == [expected])
        #expect(expected.contains("api.openai.com"))
        #expect(!controller.isSpeaking)
    }

    @Test func speakingFromAPanelRecordsTheSourceAndKeepsTheHUDHidden() {
        let (controller, speech, toaster) = make()
        controller.speak("summary text", from: .summary)
        #expect(speech.spoken.map(\.text) == ["summary text"])
        #expect(controller.active == .summary)
        #expect(controller.isSpeaking)
        #expect(toaster.states.isEmpty)
    }

    @Test func theHotkeyStillShowsTheHUD() async {
        let (controller, _, toaster) = make()
        await controller.toggle(text: { "selection" })
        #expect(controller.active == .hotkey)
        #expect(toaster.states.contains { if case .speaking = $0 { return true } else { return false } })
    }

    @Test func pauseAndResumeFlipTheFlagAndDriveTheBackend() {
        let (controller, speech, _) = make()
        controller.speak("text", from: .refineRefined)
        controller.pauseOrResume()
        #expect(speech.pauseCount == 1)
        #expect(controller.isPaused)
        #expect(controller.isSpeaking)
        controller.pauseOrResume()
        #expect(speech.resumeCount == 1)
        #expect(!controller.isPaused)
    }

    @Test func pausingWhenNothingIsSpeakingIsANoOp() {
        let (controller, speech, _) = make()
        controller.pauseOrResume()
        #expect(speech.pauseCount == 0)
        #expect(!controller.isPaused)
    }

    @Test func stopClearsEverything() {
        let (controller, speech, _) = make()
        controller.speak("text", from: .summary)
        controller.pauseOrResume()
        controller.stop()
        #expect(speech.stopCount == 1)
        #expect(!controller.isSpeaking)
        #expect(!controller.isPaused)
        #expect(controller.active == nil)
    }

    @Test func aSecondSourceSupersedesTheFirst() {
        let (controller, speech, _) = make()
        controller.speak("original", from: .refineOriginal)
        controller.speak("refined", from: .refineRefined)
        #expect(controller.active == .refineRefined)
        #expect(speech.spoken.map(\.text) == ["original", "refined"])
    }

    /// One in-flight job (invariant 7): ⌥S while the panel is speaking stops it rather than
    /// starting a second read.
    @Test func theHotkeyStopsPanelPlayback() async {
        let (controller, speech, _) = make()
        controller.speak("panel text", from: .summary)
        await controller.toggle(text: { Issue.record("must not read the selection"); return "" })
        #expect(speech.stopCount == 1)
        #expect(controller.active == nil)
        #expect(!controller.isSpeaking)
    }

    @Test func speakingBlankTextToastsInsteadOfStarting() {
        let (controller, speech, toaster) = make()
        controller.speak("   \n ", from: .summary)
        #expect(speech.spoken.isEmpty)
        #expect(controller.active == nil)
        #expect(!toaster.messages.isEmpty)
    }

    @Test func theBackendFinishingOnItsOwnClearsTheSource() {
        let (controller, speech, _) = make()
        controller.speak("text", from: .summary)
        speech.finish()
        #expect(controller.active == nil)
        #expect(!controller.isSpeaking)
    }

    @Test func speakingThroughANotReadySourceToastsInsteadOfStayingSilent() {
        let speech = ScriptedSpeech()
        let toaster = ScriptedToaster()
        var settings = Settings.default
        settings.speech.source = .local
        settings.speech.localModelID = "piper-ru"          // chosen but never downloaded
        let controller = SpeakController(speech: speech,
                                         toaster: toaster,
                                         settings: { settings },
                                         modelStates: { [:] })

        controller.speak("Прочитай это", from: .hotkey)

        #expect(speech.spoken.isEmpty)
        #expect(toaster.messages.last?.contains("has not been downloaded") == true)
    }

    @Test func speakingThroughAReadySourceIsUnaffected() {
        let speech = ScriptedSpeech()
        let toaster = ScriptedToaster()
        var settings = Settings.default
        settings.speech.source = .local
        settings.speech.localModelID = "piper-ru"
        let controller = SpeakController(speech: speech,
                                         toaster: toaster,
                                         settings: { settings },
                                         modelStates: { ["piper-ru": .downloaded] })

        controller.speak("Прочитай это", from: .hotkey)

        #expect(speech.spoken.map(\.text) == ["Прочитай это"])
    }

    @Test func theSystemSourceNeverBlocks() {
        let speech = ScriptedSpeech()
        let controller = SpeakController(speech: speech,
                                         toaster: ScriptedToaster(),
                                         settings: { Settings.default },
                                         modelStates: { [:] })
        controller.speak("Hello", from: .hotkey)
        #expect(speech.spoken.count == 1)
    }
}
