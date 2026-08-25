import AVFoundation
import Foundation

struct Voice: Identifiable, Sendable, Equatable {
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String    // BCP-47, e.g. "en-US"
    let quality: String     // "default" | "enhanced" | "premium"
}

@MainActor protocol SpeechSynthesizing: AnyObject {
    var isSpeaking: Bool { get }
    /// Called whenever `isSpeaking` changes, including when an utterance finishes by itself.
    var onStateChange: (@MainActor () -> Void)? { get set }
    func voices() -> [Voice]
    func speak(_ text: String, settings: SpeechSettings)
    func stop()
}

@MainActor final class AVSpeechService: NSObject, SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    private(set) var isSpeaking = false
    var onStateChange: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // `nonisolated`: pure functions touching no actor-isolated state, so the tests (and any
    // other caller) can invoke them synchronously without hopping to the main actor.
    nonisolated static func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: "enhanced"
        case .premium: "premium"
        default: "default"
        }
    }

    nonisolated static func clampedRate(_ rate: Float) -> Float {
        min(max(rate, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
    }

    nonisolated static func clampedPitch(_ pitch: Float) -> Float { min(max(pitch, 0.5), 2.0) }

    nonisolated static func clampedVolume(_ volume: Float) -> Float { min(max(volume, 0), 1) }

    func voices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            Voice(id: voice.identifier, name: voice.name, language: voice.language,
                  quality: Self.qualityLabel(voice.quality))
        }
    }

    func speak(_ text: String, settings: SpeechSettings) {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: text)
        if let id = settings.voiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        utterance.rate = Self.clampedRate(settings.rate)
        utterance.pitchMultiplier = Self.clampedPitch(settings.pitch)
        utterance.volume = Self.clampedVolume(settings.volume)
        setSpeaking(true)
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    fileprivate func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onStateChange?()
    }
}

extension AVSpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.setSpeaking(false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.setSpeaking(false) }
    }
}
