import Foundation

enum PresetKind: String, Codable, Sendable, CaseIterable {
    case refine
    case summarize
}

/// A user-editable prompt. Rendering and factory seeding arrive in Plan 4.
struct PromptPreset: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var kind: PresetKind
    /// Base language code from `PromptLanguage`. Decides which set the preset belongs to.
    var language: String
    var name: String
    var systemPrompt: String
    /// Must contain "{text}". May also contain "{instruction}" and "{language}".
    var userTemplate: String
    var isFactory: Bool
    var sortOrder: Int

    init(id: UUID = UUID(), kind: PresetKind, language: String = PromptLanguage.english.code,
         name: String, systemPrompt: String, userTemplate: String, isFactory: Bool, sortOrder: Int) {
        self.id = id
        self.kind = kind
        self.language = language
        self.name = name
        self.systemPrompt = systemPrompt
        self.userTemplate = userTemplate
        self.isFactory = isFactory
        self.sortOrder = sortOrder
    }
}

extension PromptPreset {
    /// Hand-written so a preset stored before languages existed decodes as English instead of
    /// throwing. In an extension so the struct keeps its memberwise initialiser — the pattern
    /// `Settings` and `SpeechSettings` already use.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(PresetKind.self, forKey: .kind)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? PromptLanguage.english.code
        name = try c.decode(String.self, forKey: .name)
        systemPrompt = try c.decode(String.self, forKey: .systemPrompt)
        userTemplate = try c.decode(String.self, forKey: .userTemplate)
        isFactory = try c.decode(Bool.self, forKey: .isFactory)
        sortOrder = try c.decode(Int.self, forKey: .sortOrder)
    }
}

enum PresetError: Error, LocalizedError, Equatable, Sendable {
    case lastOfKind(PresetKind)
    case notFound

    var errorDescription: String? {
        switch self {
        case .lastOfKind(let kind): "At least one \(kind.displayName.lowercased()) preset must exist."
        case .notFound: "That preset no longer exists."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .lastOfKind: "Add another preset first, then delete this one."
        case .notFound: "Reopen Settings and try again."
        }
    }
}

extension PresetKind {
    var displayName: String {
        switch self {
        case .refine: "Refine"
        case .summarize: "Summarize"
        }
    }
}

extension Settings {
    /// Key for `defaultPresetIDs`, e.g. "refine.ru".
    static func presetKey(_ kind: PresetKind, _ language: String) -> String {
        "\(kind.rawValue).\(language)"
    }

    /// Presets of one kind and language, ordered by `sortOrder` (ties keep storage order).
    func presets(of kind: PresetKind, language: String) -> [PromptPreset] {
        presets.enumerated()
            .filter { $0.element.kind == kind && $0.element.language == language }
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
    }

    func preset(id: UUID) -> PromptPreset? { presets.first { $0.id == id } }

    func defaultPresetID(for kind: PresetKind, language: String) -> UUID? {
        defaultPresetIDs[Settings.presetKey(kind, language)]
    }

    /// The configured default, or the first preset of that kind and language when the ID is
    /// missing or dangling.
    func defaultPreset(for kind: PresetKind, language: String) -> PromptPreset? {
        if let id = defaultPresetID(for: kind, language: language), let found = preset(id: id),
           found.kind == kind, found.language == language {
            return found
        }
        return presets(of: kind, language: language).first
    }

    mutating func setDefaultPreset(id: UUID, for kind: PresetKind, language: String) {
        defaultPresetIDs[Settings.presetKey(kind, language)] = id
    }

    /// Appends the preset at the end of its kind *and* language, and returns the stored value.
    @discardableResult
    mutating func addPreset(_ preset: PromptPreset) -> PromptPreset {
        var stored = preset
        stored.sortOrder = (presets(of: stored.kind, language: stored.language)
            .map(\.sortOrder).max() ?? -1) + 1
        presets.append(stored)
        if defaultPresetID(for: stored.kind, language: stored.language) == nil {
            setDefaultPreset(id: stored.id, for: stored.kind, language: stored.language)
        }
        return stored
    }

    mutating func updatePreset(_ preset: PromptPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    /// The "at least one must remain" rule is scoped to a kind *and* language: deleting the
    /// last Russian refine preset would leave that language unusable even though English
    /// still has seven.
    mutating func deletePreset(id: UUID) throws {
        guard let victim = preset(id: id) else { throw PresetError.notFound }
        guard presets(of: victim.kind, language: victim.language).count > 1 else {
            throw PresetError.lastOfKind(victim.kind)
        }
        presets.removeAll { $0.id == id }
        if defaultPresetID(for: victim.kind, language: victim.language) == id,
           let replacement = presets(of: victim.kind, language: victim.language).first {
            setDefaultPreset(id: replacement.id, for: victim.kind, language: victim.language)
        }
    }

    /// Moves a preset within its own kind and language and renumbers that group 0..<n.
    mutating func movePreset(id: UUID, to index: Int) {
        guard let moved = preset(id: id) else { return }
        var ordered = presets(of: moved.kind, language: moved.language)
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let item = ordered.remove(at: from)
        ordered.insert(item, at: min(max(index, 0), ordered.count))
        for (newOrder, preset) in ordered.enumerated() {
            guard let slot = presets.firstIndex(where: { $0.id == preset.id }) else { continue }
            presets[slot].sortOrder = newOrder
        }
    }
}
