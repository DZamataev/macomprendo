import Foundation
@testable import Macomprendo

@MainActor final class ScriptedSpeech: SpeechSynthesizing {
    struct Spoken: Equatable {
        var text: String
        var settings: SpeechSettings
    }

    var isSpeaking = false
    var isPaused = false
    var onStateChange: (@MainActor () -> Void)?
    var onError: (@MainActor (Error) -> Void)?
    var available: [Voice] = []
    /// Per-source catalogs for the Speech tab. Falls back to `available` for a source that is
    /// not listed, so tests that only care about one list keep working.
    var availableBySource: [SpeechSource: [Voice]] = [:]
    private(set) var spoken: [Spoken] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0

    func voices() -> [Voice] { available }

    func voices(for source: SpeechSource) -> [Voice] { availableBySource[source] ?? available }

    func speak(_ text: String, settings: SpeechSettings) {
        spoken.append(Spoken(text: text, settings: settings))
        isSpeaking = true
        isPaused = false
        onStateChange?()
    }

    func stop() {
        stopCount += 1
        isSpeaking = false
        isPaused = false
        onStateChange?()
    }

    func pause() {
        pauseCount += 1
        isPaused = true
        onStateChange?()
    }

    func resume() {
        resumeCount += 1
        isPaused = false
        onStateChange?()
    }

    /// Simulates the synthesizer reaching the end of the utterance.
    func finish() {
        isSpeaking = false
        isPaused = false
        onStateChange?()
    }

    /// Simulates a backend failure. Mirrors the ordering contract every real backend keeps:
    /// state change first (hides the HUD), error second (shows the toast).
    func failWith(_ error: Error) {
        isSpeaking = false
        isPaused = false
        onStateChange?()
        onError?(error)
    }
}
