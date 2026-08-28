import Foundation

/// Decides whether the Dock icon is visible. A set of owners rather than a flag, because the
/// onboarding wizard and the Settings window can be open at once and closing one must not take
/// the icon away from the other. The HUD and the Quick Panel are `NSPanel`s and are never
/// owners.
@MainActor final class DockIconCoordinator {
    enum Owner: Hashable, Sendable {
        case settings
        case onboarding
    }

    private(set) var owners: Set<Owner> = []
    private let policy: any ActivationPolicyControlling

    init(policy: any ActivationPolicyControlling) {
        self.policy = policy
    }

    func open(_ owner: Owner) {
        let wasEmpty = owners.isEmpty
        guard owners.insert(owner).inserted else { return }
        // Only the empty→non-empty transition needs to show the icon; a second owner
        // joining one that already has it showing is a no-op for the policy.
        if wasEmpty { policy.setDockIconVisible(true) }
    }

    func close(_ owner: Owner) {
        guard owners.remove(owner) != nil else { return }
        policy.setDockIconVisible(!owners.isEmpty)
    }
}
