import Foundation

/// Composition root. Every real service is constructed here and nowhere else —
/// Plans 3 and 4 add the hotkey service, recorder, providers and controllers as
/// further properties on this struct.
@MainActor
struct AppEnvironment {
    let model: AppModel

    static func live() -> AppEnvironment {
        AppEnvironment(
            model: AppModel(store: UserDefaultsSettingsStore(), keychain: SystemKeychainStore())
        )
    }
}
