import AVFoundation
import Foundation

struct Voice: Identifiable, Sendable, Equatable {
    let id: String          // AVSpeechSynthesisVoice.identifier
    let name: String
    let language: String    // BCP-47, e.g. "en-US"
    let quality: String     // "default" | "enhanced" | "premium"
}

/// One queued utterance: a stretch of text plus the voice that should read it.
/// Computing the plan is pure, so segmentation is unit-tested without AVFoundation.
struct UtterancePlan: Equatable, Sendable {
    var text: String
    var voiceID: String?
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

    /// The utterances handed to the synthesizer for the current `speak(_:settings:)` call.
    /// `didFinish`/`didCancel` callbacks for anything not in this list belong to a superseded
    /// call and are ignored, so a stop-then-speak race cannot clear the new speaking state.
    private var queued: [AVSpeechUtterance] = []

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

    nonisolated static func qualityRank(_ quality: String) -> Int {
        switch quality {
        case "premium": 2
        case "enhanced": 1
        default: 0
        }
    }

    /// 2 = exactly the preferred tag, 1 = the same base code, 0 = anything else.
    nonisolated static func languageRank(_ language: String, preferred: String) -> Int {
        if language.caseInsensitiveCompare(preferred) == .orderedSame { return 2 }
        func base(_ tag: String) -> String { tag.split(separator: "-").first.map { $0.lowercased() } ?? "" }
        return base(language) == base(preferred) ? 1 : 0
    }

    /// The best installed voice for a script: `ru-RU` for Cyrillic and `en-US` for Latin
    /// first, then any other voice in the same script, preferring premium > enhanced >
    /// default. Ties break on name then identifier so the choice is stable.
    nonisolated static func fallbackVoice(for script: ScriptClass, in voices: [Voice]) -> Voice? {
        guard script != .neutral else { return nil }
        let preferred = script == .cyrillic ? "ru-RU" : "en-US"
        return voices
            .filter { LanguageSegmenter.script(ofLanguage: $0.language) == script }
            .sorted { lhs, rhs in
                let lhsKey = (languageRank(lhs.language, preferred: preferred), qualityRank(lhs.quality))
                let rhsKey = (languageRank(rhs.language, preferred: preferred), qualityRank(rhs.quality))
                if lhsKey != rhsKey { return lhsKey > rhsKey }
                return (lhs.name, lhs.id) < (rhs.name, rhs.id)
            }
            .first
    }

    /// What to enqueue for `text`. When every run matches the configured voice's script the
    /// result is a single utterance holding the original text — byte for byte what the
    /// service did before segmentation existed.
    nonisolated static func utterancePlan(
        text: String,
        settings: SpeechSettings,
        voices: [Voice],
        minRunLength: Int = LanguageSegmenter.defaultMinRunLength
    ) -> [UtterancePlan] {
        guard !text.isEmpty else { return [] }
        let configured = voices.first { $0.id == settings.voiceID }
        let configuredScript = configured.map { LanguageSegmenter.script(ofLanguage: $0.language) } ?? .latin
        let runs = LanguageSegmenter.runs(in: text, minRunLength: minRunLength)
        let needsSwitching = runs.contains { $0.script != .neutral && $0.script != configuredScript }
        guard runs.count > 1, needsSwitching else {
            return [UtterancePlan(text: text, voiceID: settings.voiceID)]
        }
        return runs.map { run in
            guard run.script != .neutral, run.script != configuredScript else {
                return UtterancePlan(text: run.text, voiceID: settings.voiceID)
            }
            return UtterancePlan(text: run.text,
                                 voiceID: fallbackVoice(for: run.script, in: voices)?.id ?? settings.voiceID)
        }
    }

    func voices() -> [Voice] {
        AVSpeechSynthesisVoice.speechVoices().map { voice in
            Voice(id: voice.identifier, name: voice.name, language: voice.language,
                  quality: Self.qualityLabel(voice.quality))
        }
    }

    func speak(_ text: String, settings: SpeechSettings) {
        queued.removeAll()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let plan = Self.utterancePlan(text: text, settings: settings, voices: voices())
        guard !plan.isEmpty else {
            setSpeaking(false)
            return
        }
        // AVSpeechSynthesizer plays a queue natively, so one `speak` per run is enough.
        queued = plan.map { item in
            let utterance = AVSpeechUtterance(string: item.text)
            if let id = item.voiceID, let voice = AVSpeechSynthesisVoice(identifier: id) {
                utterance.voice = voice
            }
            utterance.rate = Self.clampedRate(settings.rate)
            utterance.pitchMultiplier = Self.clampedPitch(settings.pitch)
            utterance.volume = Self.clampedVolume(settings.volume)
            return utterance
        }
        setSpeaking(true)
        for utterance in queued { synthesizer.speak(utterance) }
    }

    func stop() {
        queued.removeAll()
        synthesizer.stopSpeaking(at: .immediate)
        setSpeaking(false)
    }

    fileprivate func setSpeaking(_ value: Bool) {
        guard isSpeaking != value else { return }
        isSpeaking = value
        onStateChange?()
    }

    /// `isSpeaking` drops only once the *last* queued utterance is done.
    fileprivate func finished(_ token: ObjectIdentifier) {
        guard let index = queued.firstIndex(where: { ObjectIdentifier($0) == token }) else { return }
        queued.remove(at: index)
        if queued.isEmpty { setSpeaking(false) }
    }
}

extension AVSpeechService: AVSpeechSynthesizerDelegate {
    // `AVSpeechUtterance` is not `Sendable`, so the identity token crosses the hop instead
    // of the object itself.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(token) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        let token = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finished(token) }
    }
}
