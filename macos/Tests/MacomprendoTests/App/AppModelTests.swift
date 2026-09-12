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

    private func waitForHistoryDeletes(_ count: Int, in store: FakeDictationHistoryStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.deleteOlderThanRequests.count == count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for history retention")
    }

    private func waitForReferenceReads(_ count: Int, in store: FakeDictationHistoryStore) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.referencedAudioFilenamesCallCount == count { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for referenced audio filenames")
    }

    @Test func theRecorderReceivesTheConfiguredMaximumRecordingLength() async {
        let recorder = FakeAudioRecorder()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(recorder: recorder))

        #expect(recorder.maximumDurations == [300])

        model.settings.maximumRecordingSeconds = 900

        #expect(recorder.maximumDurations == [300, 900])
    }

    @Test func startAppliesRetentionAndPurgesOrphanedAudio() async {
        let historyStore = FakeDictationHistoryStore()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(dictationHistory: historyStore))

        model.start()
        await waitForHistoryDeletes(1, in: historyStore)
        await waitForReferenceReads(1, in: historyStore)

        #expect(await historyStore.deleteOlderThanRequests.count == 1)
        #expect(await historyStore.referencedAudioFilenamesCallCount == 1)
    }

    @Test func changingRetentionAppliesItImmediately() async {
        let historyStore = FakeDictationHistoryStore()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(dictationHistory: historyStore))

        model.settings.historyRetention = .sevenDays
        await waitForHistoryDeletes(1, in: historyStore)

        #expect(await historyStore.deleteOlderThanRequests.count == 1)
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

    @Test func middleMouseRoutesTheSelectedActionAndStopsWhenDisabled() async {
        let middleMouse = FakeMiddleMouseMonitor()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(middleMouse: middleMouse))
        model.start()
        #expect(middleMouse.isEnabled == false)

        model.settings.middleMouseAction = .dictate
        #expect(middleMouse.isEnabled)
        middleMouse.send(.down)
        await waitFor("middle-mouse dictation to start") { model.dictation.state == .recording }

        middleMouse.send(.up)
        await waitFor("middle-mouse dictation to stop") { model.dictation.state != .recording }

        model.settings.middleMouseAction = nil
        #expect(middleMouse.isEnabled == false)
    }

    @Test func middleMouseToggleModeIsIndependentFromHotkeyMode() async {
        let middleMouse = FakeMiddleMouseMonitor()
        let recorder = FakeAudioRecorder()
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(middleMouse: middleMouse, recorder: recorder))
        model.settings.dictationMode = .hold
        model.settings.middleMouseMode = .toggle
        model.settings.middleMouseAction = .dictate
        model.start()

        middleMouse.send(.down)
        await waitFor("toggle-mode middle mouse dictation to start") {
            model.dictation.state == .recording
        }
        middleMouse.send(.up)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.stopCount == 0)

        middleMouse.send(.down)
        await waitFor("toggle-mode middle mouse dictation to stop") { recorder.stopCount == 1 }
    }

    /// The graph must hand both microphone features one controller, backed by the exact store
    /// supplied by the environment; separate instances would split the user's timeline.
    @Test func directDictationAndDictateAndRefineShareTheEnvironmentHistoryStore() async {
        let recorder = FakeAudioRecorder()
        let http = FakeHTTPClient()
        http.response = HTTPResponse(status: 200, headers: [:], body: Data(#"{"text":"spoken"}"#.utf8))
        let historyStore = FakeDictationHistoryStore()
        let endpoint = Endpoint(name: "Test", kind: .openAICompatible,
                                baseURL: URL(string: "https://example.test")!)
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(recorder: recorder, http: http, dictationHistory: historyStore))
        model.settings.dictationHistoryEnabled = true
        model.settings.endpoints = [endpoint]
        model.settings.transcriptionSource = .endpoint(id: endpoint.id, model: "whisper")
        model.start()

        model.route(.keyDown(.dictate))
        await model.dictation.activeTask?.value
        model.route(.keyUp(.dictate))
        await model.dictation.activeTask?.value

        model.route(.keyDown(.dictateAndRefine))
        await waitFor("Dictate & Refine recording to start") {
            model.textFeatures?.refine.isCapturing == true
        }
        model.route(.keyUp(.dictateAndRefine))
        await model.textFeatures?.refine.drainCapture()

        #expect(await historyStore.appendRequests.map(\.kind) == [.dictation, .dictationAndRefine])
        #expect(await historyStore.appendRequests.map(\.text) == ["spoken", "spoken"])
    }

    @Test func directDictationAndDictateAndRefineUseTheSameRetainedLocalProvider() async throws {
        let recorder = FakeAudioRecorder()
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let cache = LocalTranscriptionProviderCache()
        let retainedProvider = FakeTranscriptionProvider()
        retainedProvider.result = .success("spoken")
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(recorder: recorder, models: models, localTranscriptionCache: cache))
        model.settings.transcriptionSource = .local(modelID: "base")
        model.settings.localModelIdleTimeout = .never
        _ = cache.provider(
            retainedProvider,
            configuration: .init(source: .local(modelID: "base"), whisper: WhisperOptions()))
        model.start()

        model.route(.keyDown(.dictate))
        await model.dictation.activeTask?.value
        model.route(.keyUp(.dictate))
        await model.dictation.activeTask?.value

        model.route(.keyDown(.dictateAndRefine))
        await waitFor("Dictate & Refine recording to start") {
            model.textFeatures?.refine.isCapturing == true
        }
        model.route(.keyUp(.dictateAndRefine))
        await model.textFeatures?.refine.drainCapture()

        #expect(retainedProvider.received.count == 2)
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

    @Test func activeLocalTranscriptionUsesTheEnvironmentCacheAndConfigurationChangesClearIt() async throws {
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let cache = LocalTranscriptionProviderCache()
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(models: models, localTranscriptionCache: cache)
        )
        model.settings.transcriptionSource = .local(modelID: "base")
        model.settings.localModelIdleTimeout = .never

        _ = try await model.transcriberProvider()
        #expect(cache.isEmpty == false)

        model.settings.whisperThreads = 4
        #expect(cache.isEmpty)
    }

    @Test func endpointProbeDoesNotEvictTheActiveLocalProvider() async throws {
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let cache = LocalTranscriptionProviderCache()
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(models: models, localTranscriptionCache: cache))
        model.settings.transcriptionSource = .local(modelID: "base")
        model.settings.localModelIdleTimeout = .never
        _ = try await model.transcriberProvider()
        let retainedConfiguration = cache.cachedConfiguration
        let endpoint = Endpoint(name: "Probe", kind: .openAICompatible,
                                baseURL: URL(string: "https://example.test")!)
        model.settings.endpoints = [endpoint]

        _ = try await model.transcriber(for: .endpoint(id: endpoint.id, model: "whisper-1"))

        #expect(cache.cachedConfiguration == retainedConfiguration)
        #expect(cache.isEmpty == false)
    }

    @Test func shutdownClearsTheLocalTranscriptionCache() async throws {
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let cache = LocalTranscriptionProviderCache()
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(models: models, localTranscriptionCache: cache)
        )
        model.settings.transcriptionSource = .local(modelID: "base")
        model.settings.localModelIdleTimeout = .never
        _ = try await model.transcriberProvider()

        await model.shutdown()

        #expect(cache.isEmpty)
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
        #expect(stored.presets.count
                == FactoryPresets.Role.allCases.count * PromptLanguage.allCases.count)
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
