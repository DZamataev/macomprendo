import AppKit
import Foundation
import Testing
@testable import Macomprendo

@Suite struct HUDLayoutTests {
    @Test func centersThePanelHorizontallyOnTheScreen() {
        let origin = HUDLayout.origin(panelSize: CGSize(width: 260, height: 92),
                                      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
                                      topInset: 24)
        #expect(origin.x == 590)          // (1440 - 260) / 2
    }

    @Test func sitsBelowTheMenuBarOfTheVisibleArea() {
        let origin = HUDLayout.origin(panelSize: CGSize(width: 260, height: 92),
                                      screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                      visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875),
                                      topInset: 24)
        #expect(origin.y == 759)          // 875 - 92 - 24
    }

    @Test func honoursTheOriginOfASecondaryScreen() {
        let origin = HUDLayout.origin(panelSize: CGSize(width: 200, height: 100),
                                      screenFrame: CGRect(x: 1440, y: 0, width: 1000, height: 800),
                                      visibleFrame: CGRect(x: 1440, y: 0, width: 1000, height: 780),
                                      topInset: 20)
        #expect(origin.x == 1840)         // 1440 + (1000 - 200) / 2
        #expect(origin.y == 660)          // 780 - 100 - 20
    }

    @Test func defaultSizeIsTheDesignedHUDSize() {
        #expect(HUDLayout.size == CGSize(width: 260, height: 92))
        #expect(HUDLayout.topInset == 24)
    }
}

@Suite struct LevelMeterModelTests {
    @Test func silenceLightsNoBars() {
        #expect(LevelMeterModel.litBars(level: 0, count: 14) == 0)
    }

    @Test func fullScaleLightsEveryBar() {
        #expect(LevelMeterModel.litBars(level: 1, count: 14) == 14)
    }

    @Test func halfLevelLightsHalfTheBars() {
        #expect(LevelMeterModel.litBars(level: 0.5, count: 12) == 6)
    }

    @Test func clampsOutOfRangeLevels() {
        #expect(LevelMeterModel.litBars(level: -0.5, count: 12) == 0)
        #expect(LevelMeterModel.litBars(level: 2, count: 12) == 12)
    }

    @Test func zeroBarsIsSafe() {
        #expect(LevelMeterModel.litBars(level: 0.5, count: 0) == 0)
    }
}
