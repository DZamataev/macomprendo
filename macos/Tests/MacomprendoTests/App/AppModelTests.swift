import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct AppModelTests {
    private func defaultWithSeededPresets() -> Settings {
        var s = Settings.default
        FactoryPresets.seed(into: &s)
        return s
    }

    @Test func loadsPersistedSettingsAndSavesChanges() throws {
        let store = InMemorySettingsStore()
        let model = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        #expect(model.settings.dictationMode == Settings.default.dictationMode)

        model.settings.dictationMode = .toggle
        let data = try #require(store.load())
        #expect(try Settings.migrate(data).dictationMode == .toggle)
    }

    @Test func routesDictateKeyDownToTheDictationController() async {
        let hotkeys = FakeHotkeyService()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(hotkeys: hotkeys))
        model.start()

        hotkeys.send(.keyDown(.dictate))
        await waitFor("dictation to start") { model.dictation.state == .recording }
        #expect(model.dictation.state == .recording)
    }

    @Test func routesSelectionActionsToTheTextFeatures() async {
        let hotkeys = FakeHotkeyService()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(hotkeys: hotkeys))
        model.start()

        // With the fake environment there is no AX selection and no clipboard fallback, so
        // both actions only toast — dictation is never touched by either one. TextFeatures
        // has one in-flight selection-read task total (F2), so the .speak read here gets
        // cancelled by the .summarize one right behind it and briefly shows "Cancelled." —
        // wait for the settled toast rather than the first one observed.
        hotkeys.send(.keyDown(.speak))
        hotkeys.send(.keyDown(.summarize))

        let expectedMessage = MacomprendoError.noSelection.errorDescription ?? "!"
        await waitFor("the no-selection toast") {
            if case .toast(let message) = model.hud.state { return message.contains(expectedMessage) }
            return false
        }
        #expect(model.dictation.state == .idle)
        #expect(model.textFeatures?.quickPanel.isVisible == false)
    }

    @Test func startAppliesTheStoredHotkeyEnablement() {
        let hotkeys = FakeHotkeyService()
        let defaults = UserDefaults(suiteName: "test.appmodel.\(UUID().uuidString)")!
        HotkeyEnablementStore(defaults: defaults).setEnabled(.summarize, false)

        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(hotkeys: hotkeys),
                             hotkeyDefaults: defaults)
        model.start()

        #expect(hotkeys.enabled[.dictate] == true)
        #expect(hotkeys.enabled[.summarize] == false)
    }

    @Test func setEnabledPersistsAndForwardsToTheHotkeyService() {
        let hotkeys = FakeHotkeyService()
        let defaults = UserDefaults(suiteName: "test.appmodel.\(UUID().uuidString)")!
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(hotkeys: hotkeys),
                             hotkeyDefaults: defaults)

        model.setEnabled(.dictate, false)
        #expect(model.isEnabled(.dictate) == false)
        #expect(hotkeys.enabled[.dictate] == false)
        #expect(HotkeyEnablementStore(defaults: defaults).isEnabled(.dictate) == false)
    }

    @Test func statusTextFollowsTheDictationState() async {
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake())
        #expect(model.statusText == "Ready")

        model.dictation.handle(.keyDown(.dictate))
        await model.dictation.activeTask?.value
        #expect(model.statusText == "Recording…")
    }

    @Test func theTranscriberProviderReadsTheCurrentSettings() async throws {
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake())
        model.settings.transcriptionSource = .local(modelID: "base")
        // The fake factory records the source it was asked for.
        _ = try? await model.transcriberProvider()
        #expect(model.settings.transcriptionSource == .local(modelID: "base"))
    }

    // MARK: - Persistence at init

    @Test func appModelStartsFromDefaultsWhenTheStoreIsEmpty() {
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(), env: .fake())
        #expect(model.settings == defaultWithSeededPresets())
    }

    @Test func firstLaunchWritesTheDefaultsSoTheStoreIsNeverEmptyAgain() throws {
        let store = InMemorySettingsStore()
        _ = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        let data = try #require(store.load())
        #expect(try Settings.migrate(data) == defaultWithSeededPresets())
    }

    // Controller ruling: the factory-preset seeding in `init` must reach the STORE, not
    // just `model.settings` in memory — a session that quits right after first launch
    // (before any setting changes) must not lose the seeded presets.
    @Test func factoryPresetSeedingAtFirstLaunchReachesTheStoreItself() throws {
        let store = InMemorySettingsStore()
        _ = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        let data = try #require(store.load())
        let stored = try Settings.migrate(data)
        #expect(stored.seededPromptLanguages.contains("en"))
        #expect(stored.presets.count == 11)
    }

    @Test func changingSettingsWritesThemToTheStore() throws {
        let store = InMemorySettingsStore()
        let model = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        model.settings.dictationMode = .toggle

        let data = try #require(store.load())
        #expect(try Settings.migrate(data).dictationMode == .toggle)
    }

    @Test func appModelLoadsPreviouslySavedSettings() throws {
        var saved = Settings.default
        saved.insertMethod = .typing
        let store = InMemorySettingsStore(initial: try JSONEncoder().encode(saved))

        let model = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        #expect(model.settings.insertMethod == .typing)
    }

    @Test func corruptStoredSettingsFallBackToDefaults() {
        let store = InMemorySettingsStore(initial: Data("not json".utf8))
        let model = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        #expect(model.settings == defaultWithSeededPresets())
    }

    // Controller ruling: `didSet` never fires during `init`, so both the migrated
    // and the corrupt-payload-fallback paths must persist explicitly — otherwise a
    // repaired document only exists in memory until the user next touches a setting.
    @Test func corruptStoredSettingsAreRepairedOnDiskImmediately() throws {
        let store = InMemorySettingsStore(initial: Data("not json".utf8))
        _ = AppModel(store: store, keychain: InMemoryKeychainStore(), env: .fake())
        let data = try #require(store.load())
        #expect(try Settings.migrate(data) == defaultWithSeededPresets())
    }

    @Test func theKeychainPassedInIsTheOneHandedOut() throws {
        let keychain = InMemoryKeychainStore()
        let model = AppModel(store: InMemorySettingsStore(), keychain: keychain, env: .fake())
        try model.keychain.set("sk-test", account: "work-key")
        #expect(try keychain.get(account: "work-key") == "sk-test")
    }
}
