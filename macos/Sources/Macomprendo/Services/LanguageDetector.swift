import Foundation
import NaturalLanguage

/// Names the language of a stretch of text. Behind a protocol so the speech planner stays a
/// pure function that tests can drive deterministically (invariant 2).
protocol LanguageDetecting: Sendable {
    /// A base BCP-47 code ("ru", "en", "zh"), or nil when the text is empty, has no letters,
    /// or the recognizer is undecided.
    func dominantLanguage(of text: String) -> String?
}

struct NLLanguageDetector: LanguageDetecting {
    func dominantLanguage(of text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let language = recognizer.dominantLanguage, language != .undetermined else {
            return nil
        }
        // NLLanguage tags Chinese as "zh-Hans"/"zh-Hant"; the voice map is keyed by base code.
        return language.rawValue.split(separator: "-").first.map(String.init)
    }
}
