import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Test func appModelStartsFromDefaultsWhenTheStoreIsEmpty() {
    let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore())
    #expect(model.settings == Settings.default)
}

@MainActor
@Test func firstLaunchWritesTheDefaultsSoTheStoreIsNeverEmptyAgain() throws {
    let store = InMemorySettingsStore()
    _ = AppModel(store: store, keychain: InMemoryKeychainStore())
    let data = try #require(store.load())
    #expect(try Settings.migrate(data) == Settings.default)
}

@MainActor
@Test func changingSettingsWritesThemToTheStore() throws {
    let store = InMemorySettingsStore()
    let model = AppModel(store: store, keychain: InMemoryKeychainStore())
    model.settings.dictationMode = .toggle

    let data = try #require(store.load())
    #expect(try Settings.migrate(data).dictationMode == .toggle)
}

@MainActor
@Test func appModelLoadsPreviouslySavedSettings() throws {
    var saved = Settings.default
    saved.insertMethod = .typing
    let store = InMemorySettingsStore(initial: try JSONEncoder().encode(saved))

    let model = AppModel(store: store, keychain: InMemoryKeychainStore())
    #expect(model.settings.insertMethod == .typing)
}

@MainActor
@Test func corruptStoredSettingsFallBackToDefaults() {
    let store = InMemorySettingsStore(initial: Data("not json".utf8))
    let model = AppModel(store: store, keychain: InMemoryKeychainStore())
    #expect(model.settings == Settings.default)
}

@MainActor
@Test func theKeychainPassedInIsTheOneHandedOut() throws {
    let keychain = InMemoryKeychainStore()
    let model = AppModel(store: InMemorySettingsStore(), keychain: keychain)
    try model.keychain.set("sk-test", account: "work-key")
    #expect(try keychain.get(account: "work-key") == "sk-test")
}
