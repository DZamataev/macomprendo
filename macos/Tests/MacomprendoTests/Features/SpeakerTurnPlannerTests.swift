import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeakerTurnPlannerTests {
    private func turn(_ start: TimeInterval, _ end: TimeInterval, _ speaker: Int) -> SpeakerTurn {
        SpeakerTurn(start: start, end: end, speaker: speaker)
    }

    private func planned(_ start: TimeInterval, _ end: TimeInterval, _ voice: Int) -> PlannedTurn {
        PlannedTurn(start: start, end: end, voice: voice)
    }

    @Test func voicesAreNumberedFromOneByFirstAppearance() {
        let plan = SpeakerTurnPlanner.plan([turn(5, 6, 0), turn(0, 1, 7), turn(2, 3, 0)])
        #expect(plan == [planned(0, 1, 1), planned(2, 3, 2), planned(5, 6, 2)])
    }

    @Test func oneVoiceAcrossAShortPauseIsOneRun() {
        let plan = SpeakerTurnPlanner.plan([turn(0, 2, 3), turn(2.7, 4, 3), turn(5, 6, 3)])
        #expect(plan == [planned(0, 4, 1), planned(5, 6, 1)])
    }

    @Test func anotherVoiceInBetweenKeepsTheRunsApart() {
        let plan = SpeakerTurnPlanner.plan([turn(0, 2, 0), turn(2.1, 2.5, 1), turn(2.6, 4, 0)])
        #expect(plan == [planned(0, 2, 1), planned(2.1, 2.5, 2), planned(2.6, 4, 1)])
    }

    @Test func aRunNeverGrowsPastTheLimit() {
        let plan = SpeakerTurnPlanner.plan([turn(0, 20, 0), turn(20.5, 35, 0)])
        #expect(plan == [planned(0, 20, 1), planned(20.5, 35, 1)])
    }

    @Test func aMonologueLongerThanTheLimitIsCutIntoEqualPieces() {
        let plan = SpeakerTurnPlanner.plan([turn(10, 85, 0)])
        #expect(plan == [planned(10, 35, 1), planned(35, 60, 1), planned(60, 85, 1)])
    }

    @Test func nothingInNothingOut() {
        #expect(SpeakerTurnPlanner.plan([]).isEmpty)
        #expect(SpeakerTurnPlanner.plan([turn(3, 3, 0)]).isEmpty)
    }
}
