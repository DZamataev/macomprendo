import Foundation

protocol SettingsPersisting: AnyObject, Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

final class UserDefaultsSettingsStore: SettingsPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Data? { defaults.data(forKey: key) }
    func save(_ data: Data) { defaults.set(data, forKey: key) }
}

/// Used by tests, SwiftUI previews and the onboarding dry-run.
final class InMemorySettingsStore: SettingsPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(initial: Data? = nil) { stored = initial }

    func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func save(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stored = data
    }
}
