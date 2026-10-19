import Combine
import Foundation
import SwiftUI

/// Owns the settings, the services and the feature controllers, and routes hotkeys to them.
@MainActor
final class AppModel: ObservableObject {
    /// The built glossary, in a reference box so the dictation controllers can be handed a
    /// closure reading it before `init` has finished constructing `self`.
    @MainActor private final class GlossaryBox {
        var packs: [GlossaryPack] = []
        var glossary = Glossary()
    }
    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            snapshot.current = settings
            if settings.transcriptionSource != oldValue.transcriptionSource {
                hud.modelCaption = HUDController.caption(for: settings.transcriptionSource)
            }
            if settings.middleMouseAction != oldValue.middleMouseAction {
                env.middleMouse.setEnabled(settings.middleMouseAction != nil)
            }
            if settings.maximumRecordingSeconds != oldValue.maximumRecordingSeconds {
                env.recorder.setMaximumDuration(TimeInterval(settings.maximumRecordingSeconds))
            }
            if settings.preferredInputDeviceUID != oldValue.preferredInputDeviceUID {
                env.recorder.setPreferredInputDevice(uid: settings.preferredInputDeviceUID)
                // The call recorder has its own engine but follows the same microphone choice.
                env.callMicrophone.setPreferredInputDevice(uid: settings.preferredInputDeviceUID)
            }
            if settings.releaseMicrophoneAfterRecording != oldValue.releaseMicrophoneAfterRecording {
                env.recorder.setReleasesInputWhenStopped(settings.releaseMicrophoneAfterRecording)
                env.callMicrophone.setReleasesInputWhenStopped(settings.releaseMicrophoneAfterRecording)
            }
            if settings.historyRetention != oldValue.historyRetention {
                Task { [weak self] in
                    guard let self, let error = await self.history.applyRetention() else { return }
                    self.hud.show(.error(ErrorText.describe(error)))
                }
            }
            env.localTranscriptionCache.configure(
                configuration: Self.localTranscriptionConfiguration(for: settings),
                idleTimeout: settings.localModelIdleTimeout)
            // Turning the switch on is the first moment the directory is worth reading:
            // a user who never enables the glossary never touches the filesystem for it.
            if settings.glossaryEnabled, !oldValue.glossaryEnabled {
                Task { [weak self] in await self?.refreshGlossary() }
            }
            if settings.glossaryManualTerms != oldValue.glossaryManualTerms {
                rebuildGlossary()
            }
            if settings.autoRecordCalls != oldValue.autoRecordCalls {
                if settings.autoRecordCalls {
                    autoCallRecorder.start()
                } else {
                    // Turning it off leaves a running automatic recording to the user.
                    autoCallRecorder.stop()
                }
            }
            persist()
        }
    }

    let keychain: any KeychainStoring
    let env: AppEnvironment
    let hud: HUDController
    let history: DictationHistoryController
    let dictation: DictationController
    let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider
    /// The file jobs' provider: the same closure as `transcriberProvider`, waiting on the
    /// local-model lane at background priority so a dictation overtakes it.
    let backgroundTranscriberProvider: @Sendable () async throws -> any TranscriptionProvider
    private(set) var textFeatures: TextFeatures?
    lazy var dockIcon = DockIconCoordinator(policy: env.activationPolicy)
    lazy var modelsViewModel = ModelsViewModel(models: env.models)
    /// The TTS half of the catalog. A second view model rather than a shared one, because each
    /// screen lists exactly one kind and `ModelsViewModel` filters at construction.
    lazy var ttsModelsViewModel = ModelsViewModel(models: env.models,
                                                  catalog: ModelCatalog.all(kind: .tts))
    lazy var dictationTabModel = DictationTabModel(holder: self)
    /// The Dictation tab's Glossary section. Constructed here so the view never builds a
    /// service, and handed the rebuild callback so an edit reaches dictation immediately.
    lazy var glossarySectionModel = GlossarySectionModel(
        holder: self,
        store: env.glossary,
        revealer: env.fileRevealer,
        glossaryChanged: { [weak self] in await self?.refreshGlossary() })
    lazy var speechTabModel = SpeechTabModel(
        speech: env.speech, holder: self, keychain: keychain, toaster: hud,
        modelStates: { [unowned self] in
            self.ttsModelsViewModel.rows.reduce(into: [:]) { $0[$1.id] = $1.state }
        })
    lazy var speechSourceModel = SpeechSourceModel(holder: self)
    lazy var microphonePickerModel = MicrophonePickerModel(
        holder: self,
        devices: env.audioInputDevices,
        settingsChanges: $settings.eraseToAnyPublisher())
    /// The menubar panel's own picker. A second instance, not a shared one: each surface owns
    /// its device-observation lifetime, so closing either never stops the other's updates, and
    /// `settingsChanges` keeps the two selections in step.
    lazy var panelMicrophonePickerModel = MicrophonePickerModel(
        holder: self,
        devices: env.audioInputDevices,
        settingsChanges: $settings.eraseToAnyPublisher())
    lazy var savedAudioModel = SavedAudioModel(history: history, revealer: env.fileRevealer)
    /// The General tab's Call recordings section: the folder, its size and the reveal action.
    lazy var callRecordingsModel = CallRecordingsSettingsModel(holder: self,
                                                               folders: env.callRecordingFolders,
                                                               revealer: env.fileRevealer)
    /// File transcription's controllers, wired to the environment's services. Every closure
    /// reads the current settings, glossary and readiness, so a job started after a settings
    /// change sees the new values.
    lazy var fileTranscription = FileTranscriptionController(
        store: env.transcriptStore,
        bookmarks: env.fileBookmarks,
        folders: env.callRecordingFolders,
        pipeline: { [unowned self] in
            LongAudioPipeline(decoder: env.mediaDecoder,
                              segmenter: env.speechSegmenter,
                              transcriber: self.backgroundTranscriberProvider,
                              language: self.settings.transcriptionLanguage)
        },
        settings: { [unowned self] in self.settings },
        glossary: { [unowned self] in self.glossary },
        readiness: { [unowned self] in self.dictationTabModel.readiness },
        transcriptsChanged: { [weak self] in
            Task { await self?.transcriptLibrary.reload() }
        },
        callFinished: { [weak self] _, _ in
            // A finished call transcript reports itself: the Transcripts window is not opened
            // for it. Longer than a dictation's toast — the user may not be looking at the
            // screen when the job lands.
            self?.hud.toast("Call transcript ready", duration: 3)
        })
    lazy var transcriptLibrary = TranscriptLibraryController(store: env.transcriptStore,
                                                             pasteboard: env.pasteboard,
                                                             bookmarks: env.fileBookmarks,
                                                             revealer: env.fileRevealer,
                                                             trash: env.fileTrash)
    lazy var transcriptPlayback = TranscriptPlaybackController(player: env.transcriptAudioPlayer,
                                                               bookmarks: env.fileBookmarks,
                                                               folders: env.callRecordingFolders,
                                                               store: env.transcriptStore)
    /// The call recorder: the two captures, the track writers, and the transcript row the
    /// transcription job takes over. Its own `AVAudioEngine` — dictation keeps recording while
    /// a call is recorded.
    lazy var callRecording = CallRecordingController(
        microphone: env.callMicrophone,
        systemAudio: env.systemAudio,
        folders: env.callRecordingFolders,
        makeWriter: env.callTrackWriter,
        permissions: env.permissions,
        store: env.transcriptStore,
        bookmarks: env.fileBookmarks,
        settings: { [unowned self] in self.settings },
        transcribe: { [unowned self] id in self.fileTranscription.resume(transcriptID: id) },
        transcriptsChanged: { [weak self] in
            Task { await self?.transcriptLibrary.reload() }
        })
    /// Starts and stops call recordings on its own while `autoRecordCalls` is on. Built from
    /// the same `callRecording` the menu drives, so there is one recorder.
    lazy var autoCallRecorder = AutoCallRecorder(
        monitor: env.audioProcesses,
        recorder: callRecording,
        apps: { [unowned self] in self.settings.autoRecordApps },
        toast: { [hud] in hud.toast($0) })
    /// The About window's content, owned here so the view never constructs a service
    /// (invariant 1). Not actually deferred to first open: SwiftUI evaluates every `Scene`'s
    /// content `ViewBuilder` — including this one's `AboutView(model: model.aboutModel)` —
    /// while building the scene graph at launch, so `lazy` only defers construction to
    /// whichever `AppModel` property is read first during that pass, not to the reader
    /// opening the window. Confirmed by tracing `AboutModel.init` at launch with the About
    /// window never opened: it still runs.
    lazy var aboutModel = AboutModel(opener: env.urlOpener)
    lazy var promptsTabModel = PromptsTabModel(
        holder: self,
        llm: { [unowned self] kind in try self.llmTarget(for: kind) })
    lazy var providersViewModel: ProvidersViewModel = {
        let factory = env.factory
        let http = env.http
        return ProvidersViewModel(
            endpoints: settings.endpoints,
            update: { [weak self] endpoints in self?.settings.endpoints = endpoints },
            keychain: keychain,
            llmFor: { try factory.llm(for: $0) },
            pullerFor: { endpoint in
                endpoint.kind == .ollama ? OllamaProvider(endpoint: endpoint, http: http) : nil
            })
    }()

    private let store: any SettingsPersisting
    private let snapshot: SettingsSnapshot
    private let glossaryBox = GlossaryBox()
    private let enablement: HotkeyEnablementStore
    /// Captured here, in the init that runs before any hotkey can start a recording: launch
    /// recovery must never finalise a recording this process started.
    private let processLaunchDate = ProcessLaunch.date
    private var hotkeyTask: Task<Void, Never>?
    private var middleMouseTask: Task<Void, Never>?
    /// How long the middle button must stay down before a hold-mode dictation opens the
    /// microphone, so a plain click (a link in a new tab) never touches it.
    static let middleMouseHoldDelay = Duration.milliseconds(600)
    private var middleMouseHoldTask: Task<Void, Never>?
    private var historyMaintenanceTask: Task<Void, Never>?
    private var transcriptMaintenanceTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(store: any SettingsPersisting,
         keychain: any KeychainStoring,
         env: AppEnvironment,
         hotkeyDefaults: UserDefaults = .standard) {
        self.store = store
        self.keychain = keychain
        self.env = env
        self.enablement = HotkeyEnablementStore(defaults: hotkeyDefaults)

        let loaded: Settings
        if let data = store.load() {
            do {
                loaded = try Settings.migrate(data)
            } catch {
                // Never log the settings content itself (may hold provider config) — just
                // that the load failed and defaults are taking over, so a corrupt or
                // future-schema document doesn't fail silently.
                Log.app.error("""
                    Settings could not be read, falling back to defaults: \
                    \(error.localizedDescription, privacy: .public)
                    """)
                loaded = .default
            }
        } else {
            loaded = .default
        }
        settings = loaded

        let snapshot = SettingsSnapshot(loaded)
        self.snapshot = snapshot
        env.localTranscriptionCache.configure(
            configuration: Self.localTranscriptionConfiguration(for: loaded),
            idleTimeout: loaded.localModelIdleTimeout)

        let hud = HUDController(presenter: env.hudPresenter)
        hud.modelCaption = HUDController.caption(for: loaded.transcriptionSource)
        self.hud = hud

        history = DictationHistoryController(
            store: env.dictationHistory,
            pasteboard: env.pasteboard,
            isEnabled: { snapshot.current.dictationHistoryEnabled },
            encoder: env.dictationAudioEncoder,
            player: env.historyAudioPlayer,
            shouldSaveRecording: { snapshot.current.saveOriginalRecording },
            recordingFormat: { snapshot.current.savedRecordingFormat },
            retention: { snapshot.current.historyRetention })

        let factory = env.factory
        let models = env.models
        let localTranscriptionCache = env.localTranscriptionCache
        let lane = env.transcriptionLane
        func makeTranscriberProvider(
            _ priority: TranscriptionLane.Priority
        ) -> @Sendable () async throws -> any TranscriptionProvider {
            {
                let settings = snapshot.current
                let options = WhisperOptions(threads: settings.whisperThreads,
                                             translate: settings.whisperTranslate)
                let configuration = LocalTranscriptionProviderCache.Configuration(
                    source: settings.transcriptionSource,
                    whisper: options)
                do {
                    let candidate = try await factory.transcriber(
                        for: settings.transcriptionSource,
                        endpoints: settings.endpoints,
                        models: models,
                        whisper: options)
                    // Concurrent remote requests are fine, so only the one local speech
                    // context goes through the lane: dictation at `.interactive`, file jobs
                    // at `.background`, so a hotkey press overtakes a file already queueing
                    // segments.
                    guard case .local = settings.transcriptionSource else { return candidate }
                    let cached = await localTranscriptionCache.provider(
                        candidate,
                        configuration: configuration)
                    return LaneTranscriptionProvider(base: cached, lane: lane,
                                                     priority: priority)
                } catch {
                    if case .local = settings.transcriptionSource {
                        await localTranscriptionCache.removeAll(ifMatching: configuration)
                    }
                    throw error
                }
            }
        }
        let transcriberProvider = makeTranscriberProvider(.interactive)
        self.transcriberProvider = transcriberProvider
        self.backgroundTranscriberProvider = makeTranscriberProvider(.background)

        dictation = DictationController(recorder: env.recorder,
                                        transcriberProvider: transcriberProvider,
                                        inserter: env.inserter,
                                        tracker: env.tracker,
                                        permissions: env.permissions,
                                        hud: hud,
                                        pasteboard: env.pasteboard,
                                        settings: { snapshot.current },
                                        escapeMonitor: env.escapeMonitor,
                                        history: history,
                                        reviewPresenter: env.reviewPresenter,
                                        glossary: { [glossaryBox] in glossaryBox.glossary })

        env.recorder.setMaximumDuration(TimeInterval(loaded.maximumRecordingSeconds))
        env.recorder.setPreferredInputDevice(uid: loaded.preferredInputDeviceUID)
        env.recorder.setReleasesInputWhenStopped(loaded.releaseMicrophoneAfterRecording)

        var seeded = settings
        FactoryPresets.seed(into: &seeded)
        if seeded != settings { settings = seeded }

        // `didSet` never fires for a property's first assignment within its own
        // initializer, and firing on a *later* one is a `@Published`-specific quirk this
        // code must not depend on (it would silently stop persisting on every launch
        // after the first, once seeding above becomes a no-op and is the only
        // assignment). Sync the snapshot and persist explicitly and unconditionally here
        // instead, so a migrated, corrupt-and-repaired, or freshly-seeded first-launch
        // document is never left sitting only in memory after `init` returns.
        snapshot.current = settings
        persist()
    }

    /// A provider for an arbitrary source, for the Dictation tab's endpoint test: the endpoint
    /// being configured there is not necessarily the one that transcribes.
    func transcriber(for source: TranscriptionSource) async throws -> any TranscriptionProvider {
        try await env.factory.transcriber(
            for: source,
            endpoints: settings.endpoints,
            models: env.models,
            whisper: WhisperOptions(threads: settings.whisperThreads,
                                    translate: settings.whisperTranslate))
    }

    /// Called once at launch: applies hotkey enablement and starts routing hotkey events.
    func start() {
        // Before anything else can start a job: no job can be running at launch, so every
        // `inProgress` transcript belongs to a job the app did not finish — and every folder
        // still marked `recording` belongs to a recording the app did not finish.
        if transcriptMaintenanceTask == nil {
            transcriptMaintenanceTask = Task { [weak self] in
                guard let self else { return }
                await self.transcriptLibrary.performLaunchMaintenance()
                await CallRecordingRecovery(
                    folders: self.env.callRecordingFolders,
                    store: self.env.transcriptStore,
                    bookmarks: self.env.fileBookmarks,
                    settings: { [weak self] in self?.settings ?? .default },
                    launchDate: self.processLaunchDate).recover()
                // Recovery creates a row per recovered recording; the list has to be read
                // again so those rows show up.
                await self.transcriptLibrary.reload()
            }
        }
        if settings.glossaryEnabled {
            Task { [weak self] in await self?.refreshGlossary() }
        }
        if historyMaintenanceTask == nil {
            historyMaintenanceTask = Task { [weak self] in
                guard let self,
                      let error = await self.history.performLaunchMaintenance()
                else { return }
                self.hud.show(.error(ErrorText.describe(error)))
            }
        }
        if textFeatures == nil {
            textFeatures = TextFeatures.live(model: self, env: env, hud: hud,
                                             transcriberProvider: transcriberProvider,
                                             history: history)
        }

        // The call recorder runs its own engine but listens to the same chosen microphone.
        env.callMicrophone.setPreferredInputDevice(uid: settings.preferredInputDeviceUID)
        env.callMicrophone.setReleasesInputWhenStopped(settings.releaseMicrophoneAfterRecording)
        if settings.autoRecordCalls {
            autoCallRecorder.start()
        }

        for action in HotkeyAction.allCases {
            env.hotkeys.setEnabled(action, enablement.isEnabled(action))
        }
        dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // `callRecording` is deliberately not forwarded: its level meters tick every 100 ms, and
        // the whole menu observes this model, so forwarding rebuilt every menu item each tick —
        // the item under the pointer lost its highlight. The call rows observe it themselves.
        // A call should not start with the app talking; the tap would not record it anyway.
        callRecording.$state
            .sink { [weak self] state in
                if case .recording = state { self?.transcriptPlayback.stop() }
            }
            .store(in: &cancellables)
        // System sleep stops the recording exactly as Stop does: the recording is finalised and
        // its transcription job starts immediately, not on the next launch.
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.willSleepNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { await self?.callRecording.systemWillSleep() }
            }
            .store(in: &cancellables)

        env.middleMouse.setEnabled(settings.middleMouseAction != nil)
        if middleMouseTask == nil {
            let events = env.middleMouse.events
            middleMouseTask = Task { [weak self] in
                for await event in events {
                    self?.route(event)
                }
            }
        }

        // The app's own status item: the scene graph deliberately shows none (the hidden
        // `MenuBarExtra` anchor only keeps launch window-free), so the panel is built here.
        if statusItem == nil, let makeStatusItem = env.makeStatusItem {
            statusItem = makeStatusItem(self)
        }

        guard hotkeyTask == nil else { return }
        let events = env.hotkeys.events
        hotkeyTask = Task { [weak self] in
            for await event in events {
                self?.route(event)
            }
        }
    }

    func route(_ event: HotkeyEvent, mode: DictationMode? = nil) {
        switch event.action {
        case .dictate:
            dictation.handle(event, mode: mode)
        case .recordCall:
            // Toggle semantics of its own; the key-up and the dictation mode mean nothing here.
            callRecording.handle(event)
        default:
            textFeatures?.handle(event, mode: mode)
        }
    }

    func route(_ event: MiddleMouseEvent) {
        guard let action = settings.middleMouseAction?.hotkeyAction else { return }
        let mode = settings.middleMouseMode
        let records = action == .dictate || action == .dictateAndRefine
        switch event {
        case .down where records && mode == .hold:
            middleMouseHoldTask?.cancel()
            middleMouseHoldTask = Task { [weak self] in
                try? await Task.sleep(for: Self.middleMouseHoldDelay)
                guard !Task.isCancelled, let self else { return }
                self.middleMouseHoldTask = nil
                self.route(.keyDown(action), mode: mode)
            }
        case .down:
            route(.keyDown(action), mode: mode)
        case .up:
            if let pending = middleMouseHoldTask {
                // Released inside the window: a plain click, so the microphone was never opened.
                pending.cancel()
                middleMouseHoldTask = nil
                return
            }
            route(.keyUp(action), mode: mode)
        }
    }

    /// A microphone kept open between recordings because releasing it is switched off.
    var holdsMicrophone: Bool { env.recorder.holdsInput || env.callMicrophone.holdsInput }

    func releaseMicrophone() {
        env.recorder.releaseInput()
        env.callMicrophone.releaseInput()
        objectWillChange.send()
    }

    func isEnabled(_ action: HotkeyAction) -> Bool {
        enablement.isEnabled(action)
    }

    func setEnabled(_ action: HotkeyAction, _ enabled: Bool) {
        enablement.setEnabled(action, enabled)
        env.hotkeys.setEnabled(action, enabled)
        objectWillChange.send()
    }

    /// Releases native local-ASR contexts before application termination is allowed to finish.
    ///
    /// Order matters: a recording in flight is finalised first — its row goes `incomplete` and
    /// no job starts — then the running file job is stopped and awaited, so the pipeline task
    /// that holds the cached provider — and, with it, the whisper context — has released it
    /// before the cache drops the model. An in-flight dictation is stopped the same way, for
    /// the same reason: a context still alive at process exit aborts in whisper.cpp v1.9.2's
    /// ggml-metal static destructor, and quitting mid-job must be a clean quit.
    func shutdown() async {
        // Stop polling first: a tick that saw the recorder idle after the stop below would
        // start a fresh recording while the process is quitting.
        autoCallRecorder.stop()
        await callRecording.shutdown()
        await fileTranscription.shutdown()
        switch dictation.state {
        case .recording, .transcribing, .inserting:
            // `cancel()` clears `activeTask`, so hold onto it first to be able to wait for the
            // transcription call it may still be inside.
            let task = dictation.activeTask
            dictation.cancel()
            await task?.value
        case .idle, .failed:
            break
        }
        env.localTranscriptionCache.removeAll()
    }

    // MARK: - The glossary

    /// The keyed set the dictation controllers normalise against.
    var glossary: Glossary { glossaryBox.glossary }

    /// Reads the Vocabulary directory and rebuilds the glossary from the enabled packs.
    ///
    /// A failure to seed is surfaced rather than swallowed (invariant 8) and the directory is
    /// still read afterwards, so a folder that exists but could not be written to keeps
    /// working. Whatever the read reports as a message reaches the user through the Glossary
    /// section, which shows `GlossaryState.message`.
    func refreshGlossary() async {
        let state: GlossaryState
        do {
            state = try await env.glossary.load()
        } catch {
            hud.show(.error(ErrorText.describe(error)))
            state = await env.glossary.reload()
        }
        glossaryBox.packs = state.enabledPacks
        rebuildGlossary()
    }

    /// Rebuilds from the packs already read, for a change that cannot have altered the files —
    /// editing the manual list.
    private func rebuildGlossary() {
        glossaryBox.glossary = Glossary(packs: glossaryBox.packs,
                                        manualTerms: settings.glossaryManualTerms)
    }

    var statusText: String {
        switch dictation.state {
        case .idle: "Ready"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        case .failed(let message): message
        }
    }

    // MARK: - Windows

    /// Show All Windows, from the environment so the panel reaches the same raiser the app
    /// was built with (and tests a fake).
    var windowRaiser: any WindowRaising { env.windowRaiser }

    /// The app's status item and popover; `nil` in tests and before `start()`.
    private(set) var statusItem: (any StatusItemHosting)?

    /// Closes the menubar panel, called by the panel's commands before they route to a
    /// window or a file chooser (spec §6); a no-op when nothing is shown.
    func closeMenuPanel() {
        statusItem?.closePanel()
    }

    /// Opening the running app again (Finder, Spotlight, Launchpad): windows that were not in
    /// front come forward first; with none, or with them already in front, the menubar panel
    /// opens — the way back to it when the status item is hidden.
    func reopen(wasActive: Bool) {
        if !wasActive, windowRaiser.hasEligibleWindows {
            windowRaiser.raiseAll()
        } else {
            statusItem?.revealPanel()
        }
    }

    private static func localTranscriptionConfiguration(
        for settings: Settings
    ) -> LocalTranscriptionProviderCache.Configuration? {
        guard case .local = settings.transcriptionSource else { return nil }
        return .init(
            source: settings.transcriptionSource,
            whisper: WhisperOptions(threads: settings.whisperThreads,
                                    translate: settings.whisperTranslate))
    }

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            store.save(try encoder.encode(settings))
        } catch {
            Log.app.error("Could not save settings: \(error.localizedDescription, privacy: .public)")
        }
    }
}
