import Foundation
import Testing
@testable import Macomprendo

@Suite struct HUDViewTests {
    @Test func showsTheModelCaptionWhileRecordingAndTranscribing() {
        #expect(HUDView.captionText(for: .recording(level: 0.2, elapsed: 1), caption: "Large v3 Turbo")
                == "Large v3 Turbo")
        #expect(HUDView.captionText(for: .transcribing, caption: "Large v3 Turbo") == "Large v3 Turbo")
    }

    @Test func hidesTheModelCaptionWhileSpeaking() {
        // .speaking is text-to-speech; naming a transcription model there would mislead.
        #expect(HUDView.captionText(for: .speaking(hint: "Esc stops"), caption: "Large v3 Turbo") == nil)
    }

    @Test func hidesTheModelCaptionInEveryTerminalState() {
        for state: HUDState in [.hidden, .success("Inserted"), .error("Nope"), .toast("Hi")] {
            #expect(HUDView.captionText(for: state, caption: "Large v3 Turbo") == nil)
        }
    }

    @Test func showsNoCaptionWhenThereIsNoneOrItIsBlank() {
        #expect(HUDView.captionText(for: .transcribing, caption: nil) == nil)
        #expect(HUDView.captionText(for: .transcribing, caption: "") == nil)
    }

    @Test func formatsElapsedTimeAsMinutesAndSeconds() {
        #expect(HUDView.elapsedText(0) == "0:00")
        #expect(HUDView.elapsedText(9.7) == "0:09")
        #expect(HUDView.elapsedText(65) == "1:05")
        #expect(HUDView.elapsedText(600) == "10:00")
    }
}
