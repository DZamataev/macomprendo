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
            persist()
        }
    }

    let keychain: any KeychainStoring
    let env: AppEnvironment
    let hud: HUDController
    let dictation: DictationController
    let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider
    private(set) var textFeatures: TextFeatures?
    lazy var modelsViewModel = ModelsViewModel(models: env.models)
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

        let hud = HUDController(presenter: env.hudPresenter)
        self.hud = hud

        let factory = env.factory
        let models = env.models
        let transcriberProvider: @Sendable () async throws -> any TranscriptionProvider = {
            let settings = snapshot.current
            return try await factory.transcriber(for: settings.transcriptionSource,
                                                 endpoints: settings.endpoints,
                                                 models: models)
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
                                        escapeMonitor: env.escapeMonitor)

        // `didSet` never fires during `init`, so a migrated or corrupt-and-repaired
        // document would otherwise sit only in memory until the user next changes a
        // setting. Persist once here so the store is never left holding a stale-schema
        // or corrupt payload after launch.
        persist()

        var seeded = settings
        FactoryPresets.seed(into: &seeded)
        if seeded != settings { settings = seeded }
    }

    /// Called once at launch: applies hotkey enablement and starts routing hotkey events.
    func start() {
        if textFeatures == nil {
            textFeatures = TextFeatures.live(model: self, env: env, hud: hud,
                                             transcriberProvider: transcriberProvider)
        }

        for action in HotkeyAction.allCases {
            env.hotkeys.setEnabled(action, enablement.isEnabled(action))
        }
        dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        guard hotkeyTask == nil else { return }
        let events = env.hotkeys.events
        hotkeyTask = Task { [weak self] in
            for await event in events {
                self?.route(event)
            }
        }
    }

    func route(_ event: HotkeyEvent) {
        switch event.action {
        case .dictate:
            dictation.handle(event)
        default:
            textFeatures?.handle(event)
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

    var statusText: String {
        switch dictation.state {
        case .idle: "Ready"
        case .recording: "Recording…"
        case .transcribing: "Transcribing…"
        case .inserting: "Inserting…"
        case .failed(let message): message
        }
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
