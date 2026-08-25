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
    /// Presets of one kind, ordered by `sortOrder` (ties keep their storage order).
    func presets(of kind: PresetKind) -> [PromptPreset] {
        presets.enumerated()
            .filter { $0.element.kind == kind }
            .sorted { ($0.element.sortOrder, $0.offset) < ($1.element.sortOrder, $1.offset) }
            .map(\.element)
    }

    func preset(id: UUID) -> PromptPreset? { presets.first { $0.id == id } }

    func defaultPresetID(for kind: PresetKind) -> UUID? {
        switch kind {
        case .refine: defaultRefinePresetID
        case .summarize: defaultSummarizePresetID
        }
    }

    /// The configured default, or the first preset of that kind when the ID is missing/dangling.
    func defaultPreset(for kind: PresetKind) -> PromptPreset? {
        if let id = defaultPresetID(for: kind), let found = preset(id: id), found.kind == kind {
            return found
        }
        return presets(of: kind).first
    }

    mutating func setDefaultPreset(id: UUID, for kind: PresetKind) {
        switch kind {
        case .refine: defaultRefinePresetID = id
        case .summarize: defaultSummarizePresetID = id
        }
    }

    /// Appends the preset at the end of its kind and returns the stored value.
    @discardableResult
    mutating func addPreset(_ preset: PromptPreset) -> PromptPreset {
        var stored = preset
        stored.sortOrder = (presets(of: stored.kind).map(\.sortOrder).max() ?? -1) + 1
        presets.append(stored)
        if defaultPresetID(for: stored.kind) == nil { setDefaultPreset(id: stored.id, for: stored.kind) }
        return stored
    }

    mutating func updatePreset(_ preset: PromptPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
    }

    mutating func deletePreset(id: UUID) throws {
        guard let victim = preset(id: id) else { throw PresetError.notFound }
        guard presets(of: victim.kind).count > 1 else { throw PresetError.lastOfKind(victim.kind) }
        presets.removeAll { $0.id == id }
        if defaultPresetID(for: victim.kind) == id, let replacement = presets(of: victim.kind).first {
            setDefaultPreset(id: replacement.id, for: victim.kind)
        }
    }

    /// Moves a preset to `index` within its own kind and renumbers that kind 0..<n.
    mutating func movePreset(id: UUID, to index: Int) {
        guard let moved = preset(id: id) else { return }
        var ordered = presets(of: moved.kind)
        guard let from = ordered.firstIndex(where: { $0.id == id }) else { return }
        let item = ordered.remove(at: from)
        ordered.insert(item, at: min(max(index, 0), ordered.count))
        for (newOrder, preset) in ordered.enumerated() {
            guard let slot = presets.firstIndex(where: { $0.id == preset.id }) else { continue }
            presets[slot].sortOrder = newOrder
        }
    }
}
