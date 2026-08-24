import Foundation

enum PresetKind: String, Codable, Sendable, CaseIterable {
    case refine
    case summarize
}

/// A user-editable prompt. Rendering and factory seeding arrive in Plan 4.
struct PromptPreset: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var kind: PresetKind
    var name: String
    var systemPrompt: String
    /// Must contain "{text}". May also contain "{instruction}" and "{language}".
    var userTemplate: String
    var isFactory: Bool
    var sortOrder: Int

    init(id: UUID = UUID(), kind: PresetKind, name: String, systemPrompt: String,
         userTemplate: String, isFactory: Bool, sortOrder: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.isFactory = isFactory
        self.sortOrder = sortOrder
    }
}
