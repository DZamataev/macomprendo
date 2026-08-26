import Foundation
@testable import Macomprendo

@MainActor final class ScriptedSpeech: SpeechSynthesizing {
    struct Spoken: Equatable {
        var text: String
        var settings: SpeechSettings
    }

    var isSpeaking = false
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?
    var available: [Voice] = []
    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0

    func voices() -> [Voice] { available }

    func speak(_ text: String, settings: SpeechSettings) {
        spoken.append(Spoken(text: text, settings: settings))
        isSpeaking = true
        onStateChange?()
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
        onStateChange?()
    }

    /// Simulates the synthesizer reaching the end of the utterance.
    func finish() {
        isSpeaking = false
        onStateChange?()
    }

    /// Simulates a backend failure. Mirrors the ordering contract every real backend keeps:
    /// state change first (hides the HUD), error second (shows the toast).
    func failWith(_ error: Error) {
        isSpeaking = false
        onStateChange?()
        onError?(error)
    }
}
