import Combine
import Foundation
import SwiftUI

/// Owns the settings, the services and the feature controllers, and routes hotkeys to them.
@MainActor
final class AppModel: ObservableObject {
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
            env.localTranscriptionCache.configure(
                configuration: Self.localTranscriptionConfiguration(for: settings),
                idleTimeout: settings.localModelIdleTimeout)
            persist()
        }
    }

    let keychain: any KeychainStoring
    let env: AppEnvironment
    let hud: HUDController
    let history: DictationHistoryController
    let dictation: DictationController
    let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider
    private(set) var textFeatures: TextFeatures?
    lazy var dockIcon = DockIconCoordinator(policy: env.activationPolicy)
    lazy var modelsViewModel = ModelsViewModel(models: env.models)
    /// The TTS half of the catalog. A second view model rather than a shared one, because each
    /// screen lists exactly one kind and `ModelsViewModel` filters at construction.
    lazy var ttsModelsViewModel = ModelsViewModel(models: env.models,
                                                  catalog: ModelCatalog.all(kind: .tts))
    lazy var dictationTabModel = DictationTabModel(holder: self)
    lazy var speechTabModel = SpeechTabModel(
        speech: env.speech, holder: self, keychain: keychain, toaster: hud,
        modelStates: { [unowned self] in
            self.ttsModelsViewModel.rows.reduce(into: [:]) { $0[$1.id] = $1.state }
        })
    lazy var speechSourceModel = SpeechSourceModel(holder: self)
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
    private let enablement: HotkeyEnablementStore
    private var hotkeyTask: Task<Void, Never>?
    private var middleMouseTask: Task<Void, Never>?
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
            isEnabled: { snapshot.current.dictationHistoryEnabled })

        let factory = env.factory
        let models = env.models
        let localTranscriptionCache = env.localTranscriptionCache
        let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider = {
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
                guard case .local = settings.transcriptionSource else { return candidate }
                return await localTranscriptionCache.provider(
                    candidate,
                    configuration: configuration)
            } catch {
                if case .local = settings.transcriptionSource {
                    await localTranscriptionCache.removeAll(ifMatching: configuration)
                }
                throw error
            }
        }
        self.transcriberProvider = transcriberProvider

        dictation = DictationController(recorder: env.recorder,
                                        transcriberProvider: transcriberProvider,
                                        inserter: env.inserter,
                                        tracker: env.tracker,
                                        permissions: env.permissions,
                                        hud: hud,
                                        pasteboard: env.pasteboard,
                                        settings: { snapshot.current },
                                        escapeMonitor: env.escapeMonitor,
                                        history: history)

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
        if textFeatures == nil {
            textFeatures = TextFeatures.live(model: self, env: env, hud: hud,
                                             transcriberProvider: transcriberProvider,
                                             history: history)
        }

        for action in HotkeyAction.allCases {
            env.hotkeys.setEnabled(action, enablement.isEnabled(action))
        }
        dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        default:
            textFeatures?.handle(event, mode: mode)
        }
    }

    func route(_ event: MiddleMouseEvent) {
        guard let action = settings.middleMouseAction?.hotkeyAction else { return }
        switch event {
        case .down: route(.keyDown(action), mode: settings.middleMouseMode)
        case .up: route(.keyUp(action), mode: settings.middleMouseMode)
        }
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
    func shutdown() async {
        env.localTranscriptionCache.removeAll()
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
