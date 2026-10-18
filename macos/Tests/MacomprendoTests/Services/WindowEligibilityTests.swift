import Foundation
import Testing
@testable import Macomprendo

/// Every kind of window the app can own, split into the two answers `WindowEligibility` gives.
/// Data, not a switch, so the state matrix below reads as one rule; `everyWindowKindHasAMatrixCell`
/// keeps a future kind from slipping past untested.
private let raisableKinds: [WindowSnapshot.Kind] = [
    .settings, .dictationHistory, .transcripts, .about, .onboarding, .quickPanel
]

private let neverRaisableKinds: [WindowSnapshot.Kind] = [
    .statusItem, .popover, .hud, .correctionReview, .sheet, .panelChooser, .other
]

@Suite struct WindowEligibilityTests {
    @Test func everyWindowKindHasAMatrixCell() {
        for kind in WindowSnapshot.Kind.allCases {
            #expect(raisableKinds.contains(kind) || neverRaisableKinds.contains(kind))
        }
    }

    // MARK: - The command may raise these

    @Test(arguments: raisableKinds)
    func anOpenUserWindowIsEligible(_ kind: WindowSnapshot.Kind) {
        #expect(WindowEligibility.isEligible(
            WindowSnapshot(kind: kind, isVisible: true, isMiniaturized: false)))
    }

    @Test(arguments: raisableKinds)
    func aMinimizedUserWindowIsStillEligible(_ kind: WindowSnapshot.Kind) {
        // AppKit reports a miniaturized window as not visible; eligibility is not visibility.
        #expect(WindowEligibility.isEligible(
            WindowSnapshot(kind: kind, isVisible: false, isMiniaturized: true)))
    }

    @Test(arguments: raisableKinds)
    func aClosedRetainedUserWindowIsNotEligible(_ kind: WindowSnapshot.Kind) {
        // `OnboardingWindowController` keeps its window after close; a retained window is not
        // an open one and must not be resurrected.
        #expect(WindowEligibility.isEligible(
            WindowSnapshot(kind: kind, isVisible: false, isMiniaturized: false)) == false)
    }

    // MARK: - Nothing may raise these

    @Test(arguments: neverRaisableKinds)
    func anExcludedWindowKindIsNeverEligible(_ kind: WindowSnapshot.Kind) {
        #expect(WindowEligibility.isEligible(
            WindowSnapshot(kind: kind, isVisible: true, isMiniaturized: false)) == false)
        #expect(WindowEligibility.isEligible(
            WindowSnapshot(kind: kind, isVisible: false, isMiniaturized: true)) == false)
        #expect(WindowEligibility.isEligible(
            WindowSnapshot(kind: kind, isVisible: false, isMiniaturized: false)) == false)
    }
}
