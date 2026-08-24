import Foundation
import Testing
@testable import Macomprendo

@Suite struct HUDViewTests {
    @Test func formatsElapsedTimeAsMinutesAndSeconds() {
        #expect(HUDView.elapsedText(0) == "0:00")
        #expect(HUDView.elapsedText(9.7) == "0:09")
        #expect(HUDView.elapsedText(65) == "1:05")
        #expect(HUDView.elapsedText(600) == "10:00")
    }
}
