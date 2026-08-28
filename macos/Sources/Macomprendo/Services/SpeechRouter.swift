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
    private let endpoint: any SpeechSynthesizing
    /// The source of the most recent `speak`. `pause`/`resume` carry no settings, so this is
    /// the only way to know which backend owns the current utterance.
    private var activeSource: SpeechSource = .system

    init(system: any SpeechSynthesizing, endpoint: any SpeechSynthesizing) {
        self.system = system
        self.endpoint = endpoint
        // Fan-in: both backends report through the router's single pair of hooks.
        for backend in [system, endpoint] {
            backend.onStateChange = { [weak self] in self?.onStateChange?() }
            backend.onError = { [weak self] error in self?.onError?(error) }
        }
    }

    var isSpeaking: Bool { system.isSpeaking || endpoint.isSpeaking }
    var isPaused: Bool { system.isPaused || endpoint.isPaused }

    /// The neutral catalog. Settings ▸ Speech asks for a specific source with `voices(for:)`.
    func voices() -> [Voice] { system.voices() }

    func voices(for source: SpeechSource) -> [Voice] { backend(for: source).voices() }

    func speak(_ text: String, settings: SpeechSettings) {
        activeSource = settings.source
        // Stopping the other backend first means switching the source mid-utterance cannot
        // leave orphaned audio playing behind the new one. Unconditional — this relies on
        // both backends' stop()/setSpeaking guarding on no-op-when-already-idle so calling
        // stop() on a backend that isn't speaking is harmless; a fake that doesn't guard
        // (e.g. ScriptedSpeech.stop() in tests) won't catch a regression here.
        backend(for: settings.source == .endpoint ? .system : .endpoint).stop()
        backend(for: settings.source).speak(text, settings: settings)
    }

    func stop() {
        system.stop()
        endpoint.stop()
    }

    func pause() { backend(for: activeSource).pause() }

    func resume() { backend(for: activeSource).resume() }

    private func backend(for source: SpeechSource) -> any SpeechSynthesizing {
        source == .endpoint ? endpoint : system
    }
}
