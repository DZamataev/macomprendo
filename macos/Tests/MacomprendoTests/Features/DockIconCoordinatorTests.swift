import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct DockIconCoordinatorTests {
    private func make() -> (DockIconCoordinator, FakeActivationPolicy) {
        let policy = FakeActivationPolicy()
        return (DockIconCoordinator(policy: policy), policy)
    }

    @Test func openingTheFirstWindowShowsTheIcon() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        #expect(policy.calls == [true])
    }

    @Test func closingTheLastWindowHidesIt() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        coordinator.close(.settings)
        #expect(policy.calls == [true, false])
        #expect(coordinator.owners.isEmpty)
    }

    /// The whole reason for a set rather than a flag: closing one of two windows must not
    /// take the icon away from the other.
    @Test func closingOneOfTwoOwnersKeepsTheIcon() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        coordinator.open(.onboarding)
        coordinator.close(.settings)
        // The second `true` is `close` re-asserting visibility while an owner remains.
        #expect(policy.calls == [true, true])
        #expect(coordinator.owners == [.onboarding])
        coordinator.close(.onboarding)
        #expect(policy.calls == [true, true, false])
    }

    @Test func openingTheSameOwnerTwiceCallsThePolicyOnce() {
        let (coordinator, policy) = make()
        coordinator.open(.settings)
        coordinator.open(.settings)
        #expect(policy.calls == [true])
    }

    @Test func closingAnOwnerThatWasNeverOpenedDoesNothing() {
        let (coordinator, policy) = make()
        coordinator.close(.onboarding)
        #expect(policy.calls.isEmpty)
    }
}
