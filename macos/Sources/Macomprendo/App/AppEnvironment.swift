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
    var recorder: any AudioRecording
    var inserter: any TextInserting
    var tracker: any FrontmostAppTracking
    var permissions: any PermissionsChecking
    var models: any ModelManaging
    var http: any HTTPClient
    var keychain: any KeychainStoring
    var factory: ProviderFactory
    var hudPresenter: (any HUDPresenting)?
    var ollamaDetector: any OllamaDetecting
    var pasteboard: any PasteboardProtocol
    var launchAtLogin: any LaunchAtLoginManaging
    var escapeMonitor: any EscapeMonitoring

    @MainActor
    static func live() -> AppEnvironment {
        let http = URLSessionHTTPClient()
        let keychain = SystemKeychainStore()
        let modelsDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Macomprendo/models", isDirectory: true)
        let pasteboard = SystemPasteboard()
        let tracker = NSWorkspaceTracker()
        let keySimulator = CGEventKeySimulator()

        return AppEnvironment(
            hotkeys: KeyboardShortcutsHotkeyService(),
            recorder: AVAudioEngineRecorder(),
            inserter: PasteTextInserter(pasteboard: pasteboard,
                                        tracker: tracker,
                                        keySimulator: keySimulator),
            tracker: tracker,
            permissions: SystemPermissions(),
            models: WhisperModelManager(directory: modelsDirectory, http: http),
            http: http,
            keychain: keychain,
            factory: ProviderFactory(http: http, keychain: keychain),
            hudPresenter: HUDWindowPresenter(),
            ollamaDetector: HTTPOllamaDetector(http: http),
            pasteboard: pasteboard,
            launchAtLogin: SMAppServiceLaunchAtLogin(),
            escapeMonitor: GlobalEscapeMonitor())
    }
}
