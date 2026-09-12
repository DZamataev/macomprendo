import AppKit
import Foundation

/// Latest settings, readable from non-isolated `@Sendable` closures (the transcriber factory).
final class SettingsSnapshot: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Settings

    init(_ settings: Settings) {
        stored = settings
    }

    var current: Settings {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Composition root: every OS-touching service the app needs, in one place, so tests can swap them.
struct AppEnvironment {
    var hotkeys: any HotkeyServicing
    var middleMouse: any MiddleMouseMonitoring
    var recorder: any AudioRecording
    var inserter: any TextInserting
    var tracker: any FrontmostAppTracking
    var permissions: any PermissionsChecking
    var models: any ModelManaging
    var http: any HTTPClient
    var keychain: any KeychainStoring
    var factory: ProviderFactory
    var localTranscriptionCache: LocalTranscriptionProviderCache
    var hudPresenter: (any HUDPresenting)?
    var ollamaDetector: any OllamaDetecting
    var pasteboard: any PasteboardProtocol
    var dictationHistory: any DictationHistoryStoring
    var dictationAudioEncoder: any DictationAudioEncoding
    var launchAtLogin: any LaunchAtLoginManaging
    var escapeMonitor: any EscapeMonitoring
    var keySimulator: any KeySimulating
    var ax: any AXReading
    var speech: any SpeechSynthesizing
    /// nil in tests: no NSPanel is created and the Quick Panel controller stays headless.
    var quickPanelHost: (@MainActor (QuickPanelView) -> any QuickPanelHosting)?
    var activationPolicy: any ActivationPolicyControlling

    @MainActor
    static func live() -> AppEnvironment {
        let http = URLSessionHTTPClient()
        let keychain = SystemKeychainStore()
        let applicationSupportDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macomprendo", isDirectory: true)
        let modelsDirectory = applicationSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
        let dictationHistory = SQLiteDictationHistoryStore(
            databaseURL: applicationSupportDirectory.appendingPathComponent("dictation-history.sqlite3"))
        let pasteboard = SystemPasteboard()
        let tracker = NSWorkspaceTracker()
        let keySimulator = CGEventKeySimulator()
        let models = LocalModelManager(directory: modelsDirectory, http: http)
        let languageDetector = NLLanguageDetector()

        return AppEnvironment(
            hotkeys: KeyboardShortcutsHotkeyService(),
            middleMouse: NSEventMiddleMouseMonitor(),
            recorder: AVAudioEngineRecorder(),
            inserter: PasteTextInserter(pasteboard: pasteboard,
                                        tracker: tracker,
                                        keySimulator: keySimulator),
            tracker: tracker,
            permissions: SystemPermissions(),
            models: models,
            http: http,
            keychain: keychain,
            factory: ProviderFactory(http: http, keychain: keychain),
            localTranscriptionCache: LocalTranscriptionProviderCache(),
            hudPresenter: HUDWindowPresenter(),
            ollamaDetector: HTTPOllamaDetector(http: http),
            pasteboard: pasteboard,
            dictationHistory: dictationHistory,
            dictationAudioEncoder: AACDictationAudioEncoder(),
            launchAtLogin: SMAppServiceLaunchAtLogin(),
            escapeMonitor: GlobalEscapeMonitor(),
            keySimulator: keySimulator,
            ax: SystemAXReader(),
            speech: SpeechRouter(
                system: AVSpeechService(detector: languageDetector),
                local: SherpaTTSService(modelManager: models,
                                        generator: SherpaSpeechGenerator(),
                                        player: AVAudioPlayerPlayer(),
                                        detector: languageDetector),
                endpoint: EndpointSpeechService(http: http,
                                                keychain: keychain,
                                                player: AVAudioPlayerPlayer())),
            quickPanelHost: { view in FloatingPanelHost(rootView: view) },
            activationPolicy: NSAppActivationPolicy())
    }
}
