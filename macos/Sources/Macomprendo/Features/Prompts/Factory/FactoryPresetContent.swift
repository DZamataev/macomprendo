import Foundation

/// One language's factory prompt content. `entries` is keyed by role; completeness is enforced
/// by `FactoryPresetsTests.everyLanguageCoversEveryRole` rather than by the type system,
/// because a dictionary literal keeps the content files flat and readable.
struct FactoryPresetContent: Sendable {
    struct Entry: Sendable {
        var name: String
        var template: String
    }

    var systemPrompt: String
    var entries: [FactoryPresets.Role: Entry]
}

extension PromptLanguage {
    var content: FactoryPresetContent {
        switch self {
        case .english: .english
        case .russian: .russian
        case .spanish: .spanish
        case .german: .german
        case .french: .french
        case .portuguese: .portuguese
        case .chinese: .chinese
        }
    }
}
