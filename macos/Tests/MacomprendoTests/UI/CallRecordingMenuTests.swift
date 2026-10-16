import Foundation
import Testing
@testable import Macomprendo

/// The menu's pure part: the ten-cell level meter the call rows render.
@Suite struct CallRecordingMenuTests {
    @Test func theMeterShowsTenCellsFilledInProportion() {
        #expect(CallLevelMeter.text(0) == "▯▯▯▯▯▯▯▯▯▯")
        #expect(CallLevelMeter.text(0.5) == "▮▮▮▮▮▯▯▯▯▯")
        #expect(CallLevelMeter.text(1.4) == "▮▮▮▮▮▮▮▮▮▮")
        #expect(CallLevelMeter.text(-1) == "▯▯▯▯▯▯▯▯▯▯")
    }

    @Test func theMeterRoundsToTheNearestCell() {
        #expect(CallLevelMeter.text(0.04) == "▯▯▯▯▯▯▯▯▯▯")
        #expect(CallLevelMeter.text(0.05) == "▮▯▯▯▯▯▯▯▯▯")
        #expect(CallLevelMeter.text(0.94) == "▮▮▮▮▮▮▮▮▮▯")
        #expect(CallLevelMeter.text(1) == "▮▮▮▮▮▮▮▮▮▮")
    }
}
