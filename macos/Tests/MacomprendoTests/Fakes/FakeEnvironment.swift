import Foundation
@testable import Macomprendo

extension AppEnvironment {
    /// An environment made entirely of fakes — no hardware, no network, no global hotkeys.
    @MainActor
    static func fake(hotkeys: any HotkeyServicing = FakeHotkeyService(),
                     middleMouse: any MiddleMouseMonitoring = FakeMiddleMouseMonitor(),
                     recorder: any AudioRecording = FakeAudioRecorder(),
                     inserter: any TextInserting = FakeTextInserter(),
                     tracker: any FrontmostAppTracking = FakeFrontmostAppTracker(),
                     permissions: any PermissionsChecking = FakePermissions(),
                     models: any ModelManaging = StubModelManager(),
                     http: any HTTPClient = FakeHTTPClient(),
                     keychain: any KeychainStoring = InMemoryKeychainStore(),
                     localTranscriptionCache: LocalTranscriptionProviderCache = LocalTranscriptionProviderCache(),
                     detector: any OllamaDetecting = FakeOllamaDetector(),
                     pasteboard: any PasteboardProtocol = FakePasteboard(),
                     dictationHistory: any DictationHistoryStoring = FakeDictationHistoryStore(),
                     dictationAudioEncoder: any DictationAudioEncoding = FakeDictationAudioEncoder(),
                     launchAtLogin: any LaunchAtLoginManaging = FakeLaunchAtLogin(),
                     escapeMonitor: any EscapeMonitoring = FakeEscapeMonitor(),
                     keySimulator: any KeySimulating = ScriptedKeySimulator(),
                     ax: any AXReading = ScriptedAXReader(text: nil),
                     speech: any SpeechSynthesizing = ScriptedSpeech(),
                     quickPanelHost: (@MainActor (QuickPanelView) -> any QuickPanelHosting)? = nil,
                     activationPolicy: any ActivationPolicyControlling = FakeActivationPolicy()) -> AppEnvironment {
        AppEnvironment(hotkeys: hotkeys,
                       middleMouse: middleMouse,
                       recorder: recorder,
                       inserter: inserter,
                       tracker: tracker,
                       permissions: permissions,
                       models: models,
                       http: http,
                       keychain: keychain,
                       factory: ProviderFactory(http: http, keychain: keychain),
                       localTranscriptionCache: localTranscriptionCache,
                       hudPresenter: nil,
                       ollamaDetector: detector,
                       pasteboard: pasteboard,
                       dictationHistory: dictationHistory,
                       dictationAudioEncoder: dictationAudioEncoder,
                       launchAtLogin: launchAtLogin,
                       escapeMonitor: escapeMonitor,
                       keySimulator: keySimulator,
                       ax: ax,
                       speech: speech,
                       quickPanelHost: quickPanelHost,
                       activationPolicy: activationPolicy)
    }
}
