import Foundation

/// Read/write access to the live `Settings` for view models and the Quick Panel controller.
@MainActor protocol SettingsHolding: AnyObject {
    var settings: Settings { get set }
}

extension AppModel: SettingsHolding {}
