import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechServiceTests {
    @Test func qualityLabelsCoverTheThreeAVQualities() {
        #expect(AVSpeechService.qualityLabel(.default) == "default")
        #expect(AVSpeechService.qualityLabel(.enhanced) == "enhanced")
        #expect(AVSpeechService.qualityLabel(.premium) == "premium")
    }

    @Test func rateIsClampedToTheAVRange() {
        #expect(AVSpeechService.clampedRate(-1) == AVSpeechUtteranceMinimumSpeechRate)
        #expect(AVSpeechService.clampedRate(99) == AVSpeechUtteranceMaximumSpeechRate)
        #expect(AVSpeechService.clampedRate(0.5) == 0.5)
    }

    @Test func pitchAndVolumeAreClamped() {
        #expect(AVSpeechService.clampedPitch(0.1) == 0.5)
        #expect(AVSpeechService.clampedPitch(9) == 2.0)
        #expect(AVSpeechService.clampedPitch(1.0) == 1.0)
        #expect(AVSpeechService.clampedVolume(-2) == 0)
        #expect(AVSpeechService.clampedVolume(5) == 1)
        #expect(AVSpeechService.clampedVolume(0.4) == 0.4)
    }

    @MainActor
    @Test func theDoubleRecordsSpeakAndStop() {
        let speech = ScriptedSpeech()
        var changes = 0
        speech.onStateChange = { changes += 1 }

        speech.speak("hello", settings: SpeechSettings(voiceID: "v", rate: 0.5, pitch: 1, volume: 1))
        #expect(speech.isSpeaking)
        #expect(speech.spoken.map(\.text) == ["hello"])

        speech.stop()
        #expect(!speech.isSpeaking)
        #expect(speech.stopCount == 1)
        #expect(changes == 2)
    }
}
