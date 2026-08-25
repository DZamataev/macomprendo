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
}
