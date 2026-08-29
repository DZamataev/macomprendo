import Foundation

/// The languages a translating preset can be pointed at. Deliberately wider than
/// `PromptLanguage`: prompts are written in the seven languages the user works *in*, while a
/// translation target is a language they want to read — those are different sets.
///
/// The name is what lands in `{chosen_language}`, and it is English for every entry. The
/// placeholder sits on its own "target language" line in each template, where a proper name
/// reads correctly whichever of the seven the prompt itself is written in, and avoids the case
/// agreement that inlining a language name into a Russian or German sentence would demand.
enum TranslationLanguages {
    static let options: [(code: String, name: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("nl", "Dutch"),
        ("pl", "Polish"),
        ("ru", "Russian"),
        ("uk", "Ukrainian"),
        ("tr", "Turkish"),
        ("zh", "Chinese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("ar", "Arabic"),
        ("hi", "Hindi")
    ]

    static func name(for code: String) -> String? {
        options.first { $0.code == code }?.name
    }
}

/// What a translating preset translates into. Two of the three are computed rather than stored,
/// because the useful answer is usually "whatever I am working in" rather than a fixed language.
enum TranslationTarget: Codable, Sendable, Equatable, Hashable {
    /// Follow the Mac's language. The default: it is what `Translate` meant before this setting
    /// existed, so an upgrading document keeps its behaviour.
    case systemLanguage
    /// Follow `Settings.promptLanguage`, so the Russian prompt set translates into Russian.
    case promptLanguage
    /// A language from `TranslationLanguages`, regardless of either.
    case fixed(String)

    static let fallbackName = "English"

    /// The value substituted into `{chosen_language}`.
    ///
    /// Falls back to English rather than to an empty string for every unknown: an OS set to a
    /// language we ship no name for, a code left behind by a list that later shrank, or a system
    /// language that cannot be read at all. A prompt whose target line is blank is worse than one
    /// aimed at the wrong language, because the model has nothing to obey.
    func resolvedName(promptLanguage: String, systemLanguageCode: String?) -> String {
        switch self {
        case .systemLanguage:
            guard let systemLanguageCode else { return Self.fallbackName }
            return TranslationLanguages.name(for: systemLanguageCode) ?? Self.fallbackName
        case .promptLanguage:
            return TranslationLanguages.name(for: promptLanguage) ?? Self.fallbackName
        case .fixed(let code):
            return TranslationLanguages.name(for: code) ?? Self.fallbackName
        }
    }

    /// How the Settings picker names this option. The system option carries what it currently
    /// resolves to, so "follow the system" is not a guess about which language that is.
    func pickerLabel(promptLanguage: String, systemLanguageCode: String?) -> String {
        switch self {
        case .systemLanguage:
            let resolved = resolvedName(promptLanguage: promptLanguage,
                                        systemLanguageCode: systemLanguageCode)
            return "System language (\(resolved))"
        case .promptLanguage:
            return "Prompt language"
        case .fixed(let code):
            return TranslationLanguages.name(for: code) ?? code
        }
    }

    /// Every option the picker offers, in order: the two computed ones, then the fixed list.
    static var allOptions: [TranslationTarget] {
        [.systemLanguage, .promptLanguage] + TranslationLanguages.options.map { .fixed($0.code) }
    }

    /// The Mac's language as a base code, the input `resolvedName` expects.
    static var currentSystemLanguageCode: String? {
        Locale.current.language.languageCode?.identifier
    }
}
