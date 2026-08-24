import Foundation
@testable import Macomprendo

extension AppEnvironment {
    /// An environment made entirely of fakes — no hardware, no network, no global hotkeys.
    @MainActor
    static func fake(hotkeys: any HotkeyServicing = FakeHotkeyService(),
                     recorder: any AudioRecording = FakeAudioRecorder(),
                     inserter: any TextInserting = FakeTextInserter(),
                     tracker: any FrontmostAppTracking = FakeFrontmostAppTracker(),
                     permissions: any PermissionsChecking = FakePermissions(),
                     models: any ModelManaging = StubModelManager(),
                     http: any HTTPClient = FakeHTTPClient(),
                     keychain: any KeychainStoring = InMemoryKeychainStore(),
                     detector: any OllamaDetecting = FakeOllamaDetector(),
                     pasteboard: any PasteboardProtocol = FakePasteboard(),
                     launchAtLogin: any LaunchAtLoginManaging = FakeLaunchAtLogin()) -> AppEnvironment {
        AppEnvironment(hotkeys: hotkeys,
                       recorder: recorder,
                       inserter: inserter,
                       tracker: tracker,
                       permissions: permissions,
                       models: models,
                       http: http,
                       keychain: keychain,
                       factory: ProviderFactory(http: http, keychain: keychain),
                       hudPresenter: nil,
                       ollamaDetector: detector,
                       pasteboard: pasteboard,
                       launchAtLogin: launchAtLogin)
    }
}
