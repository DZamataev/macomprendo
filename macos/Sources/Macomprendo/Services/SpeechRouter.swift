import Foundation

/// Dispatches every call to the backend named by `SpeechSettings.source`, so `SpeakController`
/// keeps receiving one `any SpeechSynthesizing` and knows nothing about the split.
///
/// The source is read from the `SpeechSettings` the caller already passes, so there is no
/// settings closure that could go stale and no coupling back to `AppModel`.
@MainActor final class SpeechRouter: SpeechSynthesizing {
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?

    private let system: any SpeechSynthesizing
    private let local: any SpeechSynthesizing
    private let endpoint: any SpeechSynthesizing
    /// The source of the most recent `speak`. `pause`/`resume` carry no settings, so this is
    /// the only way to know which backend owns the current utterance.
    private var activeSource: SpeechSource = .system

    init(system: any SpeechSynthesizing,
         local: any SpeechSynthesizing,
         endpoint: any SpeechSynthesizing) {
        self.system = system
        self.local = local
        self.endpoint = endpoint
        // Fan-in: every backend reports through the router's single pair of hooks.
        for backend in [system, local, endpoint] {
            backend.onStateChange = { [weak self] in self?.onStateChange?() }
            backend.onError = { [weak self] error in self?.onError?(error) }
        }
    }

    var isSpeaking: Bool { system.isSpeaking || local.isSpeaking || endpoint.isSpeaking }
    var isPaused: Bool { system.isPaused || local.isPaused || endpoint.isPaused }

    /// The neutral catalog. Settings ▸ Speech asks for a specific source with `voices(for:)`.
    func voices() -> [Voice] { system.voices() }

    func voices(for source: SpeechSource) -> [Voice] { backend(for: source).voices() }

    func speak(_ text: String, settings: SpeechSettings) {
        activeSource = settings.source
        // Stop both inactive backends first so changing sources cannot leave orphaned audio.
        for source in SpeechSource.allCases where source != settings.source {
            backend(for: source).stop()
        }
        backend(for: settings.source).speak(text, settings: settings)
    }

    func stop() {
        system.stop()
        local.stop()
        endpoint.stop()
    }

    func pause() { backend(for: activeSource).pause() }

    func resume() { backend(for: activeSource).resume() }

    private func backend(for source: SpeechSource) -> any SpeechSynthesizing {
        switch source {
        case .system: system
        case .local: local
        case .endpoint: endpoint
        }
    }
}
