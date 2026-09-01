import Foundation

/// Decides whether the Dock icon is visible. A set of owners rather than a flag, because the
/// onboarding wizard and the Settings window can be open at once and closing one must not take
/// the icon away from the other. The HUD and the Quick Panel are `NSPanel`s and are never
/// owners.
@MainActor final class DockIconCoordinator {
    enum Owner: Hashable, Sendable {
        case settings
        case onboarding
        case history
    }

    private(set) var owners: Set<Owner> = []
    private let policy: any ActivationPolicyControlling

    init(policy: any ActivationPolicyControlling) {
        self.policy = policy
    }

    /// The policy is called ONLY on a real visibility transition, in both directions.
    /// `NSAppActivationPolicy.setDockIconVisible(true)` also calls
    /// `NSApp.activate(ignoringOtherApps:)`, so re-asserting visibility while another owner
    /// is still open would yank focus to this app at the moment the user closed a window —
    /// while they were working in a different app entirely.
    func open(_ owner: Owner) {
        let wasEmpty = owners.isEmpty
        guard owners.insert(owner).inserted, wasEmpty else { return }
        policy.setDockIconVisible(true)
    }

    func close(_ owner: Owner) {
        guard owners.remove(owner) != nil, owners.isEmpty else { return }
        policy.setDockIconVisible(false)
    }
}
