import Foundation

struct RenderedPrompt: Equatable, Sendable {
    var messages: [ChatMessage]
}

/// Pure validation + substitution for prompt templates. No I/O, no state.
enum PromptRenderer {
    static let knownPlaceholders: Set<String> = ["text", "instruction", "language"]
    static let defaultLanguage = "English"

    /// Returns a list of user-facing problems; an empty array means the preset is usable.
    static func validate(_ preset: PromptPreset) -> [String] {
        var problems: [String] = []
        if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            problems.append("Name must not be empty.")
        }
        if !preset.userTemplate.contains("{text}") {
            problems.append("The user template must contain {text}.")
        }
        for name in placeholders(in: preset.userTemplate).subtracting(knownPlaceholders).sorted() {
            problems.append("Unknown placeholder {\(name)}. Supported: {text}, {instruction}, {language}.")
        }
        for name in placeholders(in: preset.systemPrompt).subtracting(knownPlaceholders).sorted() {
            problems.append("Unknown placeholder {\(name)} in the system prompt. Supported: {text}, {instruction}, {language}.")
        }
        return problems
    }

    /// Every `{identifier}` occurrence; braces around anything else are ignored.
    static func placeholders(in template: String) -> Set<String> {
        var found: Set<String> = []
        var rest = template[...]
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            let name = String(rest[afterOpen..<close])
            if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                found.insert(name)
            }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    /// Substitutes the placeholders and builds the chat messages.
    ///
    /// - A template line that mentions `{instruction}` but not `{text}` is dropped entirely when
    ///   the instruction is nil or blank, so an unused instruction never leaves an empty line.
    /// - `{language}` falls back to `defaultLanguage`.
    /// - `{text}` is substituted last so placeholder-looking text from the user is left alone.
    static func render(_ preset: PromptPreset, text: String,
                       instruction: String?, language: String?) -> RenderedPrompt {
        let instruction = (instruction ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let rawLanguage = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let language = rawLanguage.isEmpty ? defaultLanguage : rawLanguage

        var lines: [String] = []
        for line in preset.userTemplate.components(separatedBy: "\n") {
            if instruction.isEmpty, line.contains("{instruction}"), !line.contains("{text}") { continue }
            lines.append(line
                .replacingOccurrences(of: "{instruction}", with: instruction)
                .replacingOccurrences(of: "{language}", with: language)
                .replacingOccurrences(of: "{text}", with: text))
        }

        var messages: [ChatMessage] = []
        let system = preset.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty { messages.append(ChatMessage(role: .system, content: system)) }
        messages.append(ChatMessage(role: .user, content: lines.joined(separator: "\n")))
        return RenderedPrompt(messages: messages)
    }
}
