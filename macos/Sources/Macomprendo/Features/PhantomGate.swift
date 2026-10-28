import Foundation

/// How many seconds of kept text each detected language has in one long-audio run, and which
/// leads: the transcript's language as far as the phantom gate is concerned.
struct LanguageTally: Sendable, Equatable {
    private var seconds: [String: TimeInterval] = [:]
    /// Order of first appearance, so a tie keeps the language that led first.
    private var order: [String] = []

    var leader: String? {
        // Strictly more seconds to take the lead, so a tie keeps the language that led first.
        order.reduce(nil as String?) { best, language in
            guard let best else { return language }
            return seconds[language, default: 0] > seconds[best, default: 0] ? language : best
        }
    }

    /// A segment that was kept. `nil` — a provider that cannot tell — counts for nothing.
    mutating func add(_ language: String?, seconds: TimeInterval) {
        guard let language else { return }
        if self.seconds[language] == nil { order.append(language) }
        self.seconds[language, default: 0] += seconds
    }
}

/// Decides what happens to a transcribed long-audio segment whose detected language may betray
/// a phantom: whisper writing `*Sigh*` or `you` over a breath, in a language nobody on the call
/// speaks. Pure; the evidence is in spec `2026-10-28-phantom-gate-and-call-speakers` §2. No
/// list of phrases is involved: the verdict reads the detected language and how much of the
/// segment Silero calls speech, never the text.
enum PhantomGate {
    enum Verdict: Equatable, Sendable {
        case keep
        case drop
        /// Real speech whose language was guessed wrong: decode it again in this one.
        case redecode(language: String)
    }

    /// Below this share of detected speech a segment holds no speech at all. Every phantom of
    /// the spike scored 0, every real segment at least 0.22.
    static let speechFloor = 0.1
    /// Longer than this, a segment in another language is someone really speaking it: short
    /// stretches are where whisper's language guess goes wrong.
    static let redecodeLimit: TimeInterval = 5

    /// - Parameters:
    ///   - detected: the language the recogniser detected, `nil` when it cannot tell.
    ///   - expected: the run's `LanguageTally.leader`, `nil` before anything was kept.
    ///   - speechFraction: measures the segment; called only when the verdict depends on it.
    static func verdict(detected: String?, expected: String?, duration: TimeInterval,
                        speechFraction: () throws -> Double) rethrows -> Verdict {
        guard let detected, detected != expected else { return .keep }
        let silent = try speechFraction() < speechFloor
        guard let expected else { return silent ? .drop : .keep }
        if silent { return .drop }
        return duration <= redecodeLimit ? .redecode(language: expected) : .keep
    }
}
