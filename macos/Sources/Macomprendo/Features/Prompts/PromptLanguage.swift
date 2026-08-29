import Foundation

/// The languages the factory prompt set ships in. The order and the slots are frozen: the
/// slot is part of every factory preset's UUID, so renumbering would orphan stored presets.
///
/// Declared beside `PromptPreset` rather than in `Core` for the same reason `PresetKind` is:
/// `Core/Settings.swift` already stores prompt types by value.
enum PromptLanguage: String, CaseIterable, Sendable, Identifiable {
    case english = "en"
    case russian = "ru"
    case spanish = "es"
    case german = "de"
    case french = "fr"
    case portuguese = "pt"
    case chinese = "zh"

    var id: String { rawValue }

    /// The base BCP-47 code stored in `PromptPreset.language` and `Settings.promptLanguage`.
    var code: String { rawValue }

    /// The four hex digits this language contributes to a factory preset's UUID.
    var slot: String {
        switch self {
        case .english: "0000"
        case .russian: "0001"
        case .spanish: "0002"
        case .german: "0003"
        case .french: "0004"
        case .portuguese: "0005"
        case .chinese: "0006"
        }
    }

    /// The endonym: the picker lists a language the way its own speakers write it, so it is
    /// readable to the person who wants it regardless of the app's UI language.
    var displayName: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        case .spanish: "Español"
        case .german: "Deutsch"
        case .french: "Français"
        case .portuguese: "Português"
        case .chinese: "中文"
        }
    }

    /// Exact match on a base code. Region-qualified tags ("ru-RU") are deliberately rejected;
    /// callers strip the region first.
    static func named(_ code: String) -> PromptLanguage? { PromptLanguage(rawValue: code) }

    /// The shipped language for a base code, falling back to English for anything unsupported.
    static func resolve(languageCode: String?) -> PromptLanguage {
        guard let languageCode else { return .english }
        return named(languageCode) ?? .english
    }

    /// The language a fresh install starts in.
    static var systemDefault: PromptLanguage {
        resolve(languageCode: Locale.current.language.languageCode?.identifier)
    }
}
