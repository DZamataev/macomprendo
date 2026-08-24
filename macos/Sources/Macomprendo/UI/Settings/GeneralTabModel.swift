import Foundation

/// The testable core of the General tab's "Launch at login" toggle. Kept out of `GeneralTab`
/// so the reconcile-on-appear and set-on-toggle logic can be tested with `FakeLaunchAtLogin`
/// instead of driving SwiftUI.
@MainActor
final class GeneralTabModel {
    private(set) var launchAtLoginError: String?

    private let manager: any LaunchAtLoginManaging

    init(manager: any LaunchAtLoginManaging) {
        self.manager = manager
    }

    /// Called on appear. The system is the truth: if `settings.launchAtLogin` drifted from
    /// `manager.isEnabled()` — e.g. the user removed the login item in System Settings —
    /// pull `settings` back in line rather than leaving the toggle lying.
    func reconcile(settings: inout Settings) {
        let actual = manager.isEnabled()
        if settings.launchAtLogin != actual {
            settings.launchAtLogin = actual
        }
    }

    /// Applies a user-initiated toggle. On failure `settings` is left untouched and the
    /// thrown error is captured in `launchAtLoginError` for the view to surface inline.
    func setLaunchAtLogin(_ enabled: Bool, settings: inout Settings) {
        do {
            try manager.setEnabled(enabled)
            settings.launchAtLogin = enabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not change the login item: \(error.localizedDescription)"
        }
    }
}
