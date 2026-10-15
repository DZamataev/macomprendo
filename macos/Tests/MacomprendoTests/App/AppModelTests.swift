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

    @Test func theRecorderFollowsThePreferredInputDevice() async {
        let recorder = FakeAudioRecorder()
        var stored = Settings.default
        stored.preferredInputDeviceUID = "MCHOSE-USB-0001"
        let store = InMemorySettingsStore()
        store.save(try! JSONEncoder().encode(stored))
        let model = AppModel(store: store, keychain: InMemoryKeychainStore(),
                             env: .fake(recorder: recorder))

        #expect(recorder.preferredInputDeviceUIDs == ["MCHOSE-USB-0001"])

        model.settings.preferredInputDeviceUID = nil
        model.settings.preferredInputDeviceUID = "BuiltInMicrophoneDevice"

        #expect(recorder.preferredInputDeviceUIDs == ["MCHOSE-USB-0001", nil, "BuiltInMicrophoneDevice"])
    }

    @Test func startAppliesRetentionAndPurgesOrphanedAudio() async {
        let historyStore = FakeDictationHistoryStore()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(dictationHistory: historyStore))
        model.settings.dictationHistoryEnabled = true

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

    /// The graph must hand the dictation controller the environment's review presenter;
    /// constructed but unwired, the panel would never appear however well Task 2's decision
    /// logic works.
    @Test func aDictationWithAGlossaryHitReachesTheEnvironmentsReviewPresenter() async {
        let recorder = FakeAudioRecorder()
        let http = FakeHTTPClient()
        http.response = HTTPResponse(status: 200, headers: [:], body: Data(#"{"text":"открыл match hud"}"#.utf8))
        let presenter = FakeCorrectionReviewPresenter()
        let endpoint = Endpoint(name: "Test", kind: .openAICompatible,
                                baseURL: URL(string: "https://example.test")!)
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(recorder: recorder, http: http, reviewPresenter: presenter))
        model.settings.endpoints = [endpoint]
        model.settings.transcriptionSource = .endpoint(id: endpoint.id, model: "whisper")
        model.settings.glossaryEnabled = true
        model.settings.glossaryManualTerms = ["MatchHUD"]
        model.start()

        model.route(.keyDown(.dictate))
        await model.dictation.activeTask?.value
        model.route(.keyUp(.dictate))
        await model.dictation.activeTask?.value

        #expect(presenter.presented.map(\.text) == ["открыл MatchHUD"])
        #expect(presenter.presented.first?.rewrites.map(\.original) == ["match hud"])
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

    /// Quitting mid-job: the running file job is stopped — and its pipeline's references to the
    /// local provider are gone — before the cache drops the model, so the whisper context can
    /// actually be freed before the process exits. Clearing the cache under a live job was how
    /// quitting mid-job could abort in whisper.cpp's Metal teardown (ggml-metal-device.m:657).
    @Test func shutdownStopsARunningFileJobBeforeClearingTheCache() async throws {
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let cache = LocalTranscriptionProviderCache()
        let store = FakeTranscriptStore()
        let gate = AsyncGate()
        let chunk = [Float](repeating: 0, count: 16_000)
        let decoder = ScriptedMediaDecoder(duration: 10, chunks: [chunk])
        let segmenter = ScriptedSegmenter(
            acceptScript: [[SpeechSegment(start: 0, samples: chunk, sampleRate: 16_000)]])
        let model = AppModel(
            store: InMemorySettingsStore(),
            keychain: InMemoryKeychainStore(),
            env: .fake(models: models, localTranscriptionCache: cache,
                       transcriptStore: store, mediaDecoder: decoder,
                       speechSegmenter: segmenter))
        model.settings.transcriptionSource = .local(modelID: "base")
        model.settings.localModelIdleTimeout = .never
        model.dictationTabModel.modelStates = ["base": .downloaded]

        // The provider the file job will lease. Created in a scope of its own, so the cache is
        // its only strong reference and its deallocation is observable.
        weak var weakProvider: FakeTranscriptionProvider?
        do {
            let provider = FakeTranscriptionProvider()
            provider.gate = gate
            weakProvider = provider
            _ = cache.provider(provider,
                               configuration: .init(
                                   source: .local(modelID: "base"),
                                   whisper: WhisperOptions(
                                       threads: model.settings.whisperThreads,
                                       translate: model.settings.whisperTranslate)))
        }

        model.fileTranscription.transcribe(fileAt: URL(fileURLWithPath: "/files/podcast.m4a"))
        await waitFor("the first segment to reach the provider") { gate.waiterCount == 1 }

        let shutdown = Task { await model.shutdown() }
        // The row's bookkeeping lands while the job's pipeline task is still inside the
        // provider. Wait on the store, not on `fileTranscription.state`: that reads `.idle`
        // before the job's first event is processed, so it can look settled before the quit
        // was even seen.
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline,
              await store.snapshot(1)?.header.status != .incomplete {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await store.snapshot(1)?.header.status == .incomplete)
        // The cache is untouched: `shutdown()` is still waiting for the job's pipeline task,
        // which holds the provider — and the whisper context behind it — until it ends.
        #expect(cache.isEmpty == false)

        gate.open()
        await shutdown.value

        #expect(cache.isEmpty)
        #expect(weakProvider == nil)
        let row = await store.snapshot(1)
        #expect(row?.header.status == .incomplete)
        #expect(row?.header.statusReason == TranscriptLibraryController.abandonedJobReason)
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

    /// Invariant 1: the About window's link opener comes from the environment rather than
    /// being constructed by the view.
    @Test func theAboutModelLinksThroughTheEnvironmentsURLOpener() throws {
        let opener = FakeURLOpener()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(urlOpener: opener))

        model.aboutModel.open(try #require(model.aboutModel.links.first {
            $0.url == AboutModel.privacyURL
        }))

        #expect(opener.opened == [AboutModel.privacyURL])
    }

    @Test func theKeychainPassedInIsTheOneHandedOut() throws {
        let keychain = InMemoryKeychainStore()
        let model = AppModel(store: InMemorySettingsStore(), keychain: keychain, env: .fake())
        try model.keychain.set("sk-test", account: "work-key")
        #expect(try keychain.get(account: "work-key") == "sk-test")
    }

    // MARK: - The glossary

    @Test func theGlossaryIsBuiltFromTheEnabledPacksTheStoreReports() async {
        let store = FakeGlossaryStore()
        await store.setPack("xcodebuild", named: "tools")
        await store.setPack("SafeAreaView", named: "off-pack")
        await store.setEnabledNames(["tools"])
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(glossary: store))

        await model.refreshGlossary()

        #expect(model.glossary.entry(forKey: Glossary.key(for: "Xcode build"))?.canonical
                == "xcodebuild")
        // A pack on disk but absent from `packs.json` contributes nothing.
        #expect(model.glossary.entry(forKey: Glossary.key(for: "Safe Area View")) == nil)
    }

    // The manual list outranks the packs, so a change to it has to reach the built set
    // without waiting for another directory read.
    @Test func editingTheManualTermsRebuildsTheGlossary() async {
        let store = FakeGlossaryStore()
        await store.setPack("MatchHud", named: "tools")
        await store.setEnabledNames(["tools"])
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(glossary: store))
        await model.refreshGlossary()

        model.settings.glossaryManualTerms = ["MatchHUD"]

        #expect(model.glossary.entry(forKey: Glossary.key(for: "match hud"))?.canonical
                == "MatchHUD")
    }

    @Test func turningTheGlossaryOnReadsTheDirectory() async {
        let store = FakeGlossaryStore()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(glossary: store))
        #expect(await store.loadCallCount == 0)

        model.settings.glossaryEnabled = true
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline, await store.loadCallCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await store.loadCallCount == 1)
    }

    // The section is the only screen that changes which packs are on, so its rebuild callback
    // is what keeps the set the dictation controllers read in step with the folder.
    @Test func theGlossarySectionRebuildsTheGlossaryAfterAnEdit() async {
        let store = FakeGlossaryStore()
        await store.setPack("xcodebuild", named: "tools")
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(glossary: store))
        let section = model.glossarySectionModel
        #expect(model.glossary.entry(forKey: Glossary.key(for: "Xcode build")) == nil)

        await section.setEnabled(true, forPackNamed: "tools")

        #expect(model.glossary.entry(forKey: Glossary.key(for: "Xcode build"))?.canonical
                == "xcodebuild")
    }

    @Test func aFailedGlossaryLoadIsReportedAndStillReadsWhatIsThere() async {
        let store = FakeGlossaryStore()
        await store.setPack("xcodebuild", named: "tools")
        await store.setEnabledNames(["tools"])
        await store.setNextError(MacomprendoError.glossary("create the Vocabulary folder: denied"))
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(glossary: store))

        await model.refreshGlossary()

        // Seeding failed, so the user is told — nothing fails silently (invariant 8) …
        guard case .error(let message) = model.hud.state else {
            Issue.record("expected an error HUD, got \(model.hud.state)")
            return
        }
        #expect(message.contains(MacomprendoError.glossary("create the Vocabulary folder: denied")
            .errorDescription ?? "!"))
        // … and the directory is still read, so an existing folder keeps working.
        #expect(model.glossary.entry(forKey: Glossary.key(for: "Xcode build"))?.canonical
                == "xcodebuild")
    }

    @Test func theGlossarySectionRevealsTheStoresOwnDirectory() {
        let store = FakeGlossaryStore()
        let revealer = FakeFileRevealer()
        let model = AppModel(store: InMemorySettingsStore(), keychain: InMemoryKeychainStore(),
                             env: .fake(glossary: store, fileRevealer: revealer))

        model.glossarySectionModel.reveal()

        #expect(revealer.revealed == [store.directoryURL])
    }

    // MARK: - Transcription lane and file jobs

    /// A local source is one speech context, so its provider goes through the environment's
    /// lane at interactive priority: a dictation overtakes file segments already queued.
    @Test func dictationTranscriberGoesThroughTheLaneAtInteractivePriority() async throws {
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let lane = TranscriptionLane()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(models: models, transcriptionLane: lane))
        model.settings.transcriptionSource = .local(modelID: "base")

        let provider = try await model.transcriberProvider()

        let wrapped = try #require(provider as? LaneTranscriptionProvider)
        #expect(wrapped.lane === lane)
        guard case .interactive = wrapped.priority else {
            Issue.record("expected interactive priority, got \(wrapped.priority)")
            return
        }
    }

    /// A file job's segments must wait behind dictation: the same lane, background priority.
    @Test func fileTranscriberUsesBackgroundPriority() async throws {
        let models = StubModelManager()
        models.resolvedFiles["base"] = [.ggml: URL(fileURLWithPath: "/models/ggml-base.bin")]
        let lane = TranscriptionLane()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(models: models, transcriptionLane: lane))
        model.settings.transcriptionSource = .local(modelID: "base")

        let provider = try await model.backgroundTranscriberProvider()

        let wrapped = try #require(provider as? LaneTranscriptionProvider)
        #expect(wrapped.lane === lane)
        guard case .background = wrapped.priority else {
            Issue.record("expected background priority, got \(wrapped.priority)")
            return
        }
    }

    /// Concurrent remote requests are fine, so an endpoint provider is handed out unwrapped.
    @Test func anEndpointSourceIsNotWrapped() async throws {
        let endpoint = Endpoint(name: "Test", kind: .openAICompatible,
                                baseURL: URL(string: "https://example.test")!)
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake())
        model.settings.endpoints = [endpoint]
        model.settings.transcriptionSource = .endpoint(id: endpoint.id, model: "whisper-1")

        let provider = try await model.transcriberProvider()

        #expect(!(provider is LaneTranscriptionProvider))
    }

    /// No job can be running at launch, so an `inProgress` row is a job the app did not
    /// finish; `start()` repairs it before anything else can begin a job.
    @Test func startMarksAbandonedTranscriptsIncomplete() async throws {
        let store = FakeTranscriptStore()
        let id = await store.create(sourceKind: .file, title: "interrupted.m4a",
                                    sourceBookmark: nil, duration: nil,
                                    run: TranscriptionRun.from(.local(modelID: "base"),
                                                               language: nil),
                                    at: Date())
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(transcriptStore: store))

        model.start()

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.snapshot(id)?.header.status == .incomplete { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let marked = try #require(await store.snapshot(id))
        #expect(marked.header.status == .incomplete)
        #expect(marked.header.statusReason == TranscriptLibraryController.abandonedJobReason)
    }

    // MARK: - Call recording

    private func callRecordingDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppModel-calls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The `recordCall` hotkey reaches the call controller and toggles it: a press starts,
    /// the next stops, and the key-up is ignored.
    @Test func routesTheRecordCallHotkeyToTheCallController() async throws {
        let root = try callRecordingDirectory()
        let microphone = ScriptedCallCapture()
        let folders = FakeCallRecordingFolders(realDirectoryRoot: root)
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(callMicrophone: microphone,
                                        callRecordingFolders: folders))
        model.settings.callRecordingsDirectory = root.path
        model.start()

        model.route(.keyDown(.recordCall))
        await model.callRecording.drain()
        #expect(model.callRecording.isRecording)
        #expect(microphone.startCount == 1)

        model.route(.keyUp(.recordCall))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.callRecording.isRecording)

        model.route(.keyDown(.recordCall))
        await model.callRecording.drain()
        #expect(model.callRecording.state == .idle)
        #expect(microphone.stopCount == 1)
    }

    /// The call recorder runs its own `AVAudioEngine` but follows the same microphone choice
    /// as dictation: applied when routing starts, and on every change of the setting.
    @Test func theCallMicrophoneFollowsThePreferredInputDevice() throws {
        let microphone = ScriptedCallCapture()
        var stored = Settings.default
        stored.preferredInputDeviceUID = "MCHOSE-USB-0001"
        let store = InMemorySettingsStore()
        store.save(try JSONEncoder().encode(stored))
        let model = AppModel(store: store, keychain: InMemoryKeychainStore(),
                             env: .fake(callMicrophone: microphone))

        model.start()
        #expect(microphone.preferredInputDeviceUIDs == ["MCHOSE-USB-0001"])

        model.settings.preferredInputDeviceUID = nil
        model.settings.preferredInputDeviceUID = "BuiltInMicrophoneDevice"

        #expect(microphone.preferredInputDeviceUIDs
                == ["MCHOSE-USB-0001", nil, "BuiltInMicrophoneDevice"])
    }

    /// A recording a crash cut short is finalised and given an `incomplete` call transcript by
    /// launch maintenance, and the list is read again so the row shows up.
    @Test func startRecoversAnInterruptedCallRecordingIntoTheLibrary() async throws {
        let root = try callRecordingDirectory()
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let folder = try FileSystemCallRecordingFolders().create(in: root, startedAt: startedAt)
        try CallRecordingManifest(startedAt: startedAt,
                                  folderName: folder.lastPathComponent).write(to: folder)
        let folders = FakeCallRecordingFolders(realDirectoryRoot: root)
        folders.unfinished = [folder]
        let store = FakeTranscriptStore()
        let model = AppModel(store: InMemorySettingsStore(),
                             keychain: InMemoryKeychainStore(),
                             env: .fake(transcriptStore: store, callRecordingFolders: folders))
        model.settings.callRecordingsDirectory = root.path

        model.start()

        var headers: [TranscriptHeader] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            headers = (try? await store.headers()) ?? []
            // The row is created before recovery marks it incomplete and finalises the
            // manifest; wait for the settled state, not just for the row.
            if headers.first?.status == .incomplete { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let header = try #require(headers.first)
        #expect(header.sourceKind == .call)
        #expect(header.status == .incomplete)
        #expect(header.statusReason == TranscriptLibraryController.abandonedJobReason)
        #expect(header.title == CallRecordingLayout.transcriptTitle(startedAt: startedAt))
        #expect(try CallRecordingManifest.read(from: folder).status == .finished)

        await waitFor("the library to show the recovered recording") {
            model.transcriptLibrary.headers.map(\.id) == [header.id]
        }
    }
}
