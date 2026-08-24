import Foundation
import ServiceManagement

/// Whether Macomprendo is registered as a login item. Behind a protocol (spec invariant 2)
/// so `GeneralTabModel` is testable without touching `SMAppService`.
protocol LaunchAtLoginManaging: Sendable {
    /// The OS's current answer — not a cached value — so callers can reconcile drift (e.g.
    /// the user removed the login item from System Settings without going through the app).
    func isEnabled() -> Bool
    /// Registers or unregisters the login item. Throws when the user has disabled the login
    /// item in System Settings (or another `SMAppService` failure).
    func setEnabled(_ enabled: Bool) throws
}

struct SMAppServiceLaunchAtLogin: LaunchAtLoginManaging {
    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
