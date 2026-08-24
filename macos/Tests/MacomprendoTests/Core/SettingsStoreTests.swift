import Foundation
import Testing
@testable import Macomprendo

@Test func inMemoryStoreReturnsWhatWasSaved() {
    let store = InMemorySettingsStore()
    #expect(store.load() == nil)
    store.save(Data("hello".utf8))
    #expect(store.load() == Data("hello".utf8))
}

@Test func inMemoryStoreCanBeSeeded() {
    let store = InMemorySettingsStore(initial: Data("seeded".utf8))
    #expect(store.load() == Data("seeded".utf8))
}

@Test func userDefaultsStoreUsesTheGivenSuiteAndKey() throws {
    let suiteName = "macomprendo.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = UserDefaultsSettingsStore(defaults: defaults, key: "settings.v1")
    #expect(store.load() == nil)
    store.save(Data("payload".utf8))
    #expect(defaults.data(forKey: "settings.v1") == Data("payload".utf8))
    #expect(store.load() == Data("payload".utf8))
}
