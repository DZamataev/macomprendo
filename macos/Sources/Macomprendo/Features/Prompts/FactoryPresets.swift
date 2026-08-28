import Foundation

/// The presets shipped with the app. They are seeded once per language into `Settings.presets`
/// and are ordinary user data afterwards: editable, reorderable and deletable.
///
/// A preset's UUID is derived from its role and language rather than written by hand, so
/// `restoreMissing(into:)` can still tell "deleted factory preset" from "custom preset" across
/// seven languages. English is slot `0000`, which keeps the eleven IDs that shipped before
/// languages existed at exactly the values they had.
enum FactoryPresets {
    enum Role: String, CaseIterable, Sendable {
        case cleanUp, formal, casual, shorten, expand, fixGrammar, translate, translateAndOrganize
        case brief, bullets, tldr, keyActions

        var kind: PresetKind {
            switch self {
            case .cleanUp, .formal, .casual, .shorten, .expand, .fixGrammar, .translate,
                 .translateAndOrganize:
                .refine
            case .brief, .bullets, .tldr, .keyActions:
                .summarize
            }
        }

        /// The twelve hex digits this role contributes to a factory preset's UUID.
        var slot: String {
            switch self {
            case .cleanUp: "000000000001"
            case .formal: "000000000002"
            case .casual: "000000000003"
            case .shorten: "000000000004"
            case .expand: "000000000005"
            case .fixGrammar: "000000000006"
            case .translate: "000000000007"
            case .translateAndOrganize: "000000000008"
            case .brief: "000000000101"
            case .bullets: "000000000102"
            case .tldr: "000000000103"
            case .keyActions: "000000000104"
            }
        }
    }

    /// Deterministic and total: both slots are compile-time constants of the right width, so
    /// the string always parses.
    static func presetID(role: Role, language: PromptLanguage) -> UUID {
        UUID(uuidString: "F0000000-0000-0000-\(language.slot)-\(role.slot)")!
    }

    static func all() -> [PromptPreset] {
        PromptLanguage.allCases.flatMap { presets(for: $0) }
    }

    /// One language's twelve presets, `sortOrder` restarting at 0 for each kind.
    static func presets(for language: PromptLanguage) -> [PromptPreset] {
        let content = language.content
        var orders: [PresetKind: Int] = [:]
        return Role.allCases.compactMap { role in
            guard let entry = content.entries[role] else { return nil }
            let order = orders[role.kind, default: 0]
            orders[role.kind] = order + 1
            return PromptPreset(id: presetID(role: role, language: language),
                                kind: role.kind,
                                language: language.code,
                                name: entry.name,
                                systemPrompt: content.systemPrompt,
                                userTemplate: entry.template,
                                isFactory: true,
                                sortOrder: order)
        }
    }

    /// Seeds every language that has not been seeded yet. Adding a language later is one new
    /// content file plus one enum case — this loop then picks it up on the next launch.
    ///
    /// This is the authority for "this language's factory presets exist": it is idempotent per
    /// *preset ID*, not merely per `seededPromptLanguages` entry, so it is safe against any
    /// document — a fresh one, one written before that key existed (which already holds the
    /// English set and would otherwise be seeded a second time, duplicating eleven IDs), and one
    /// holding only some of a language's presets. `restoreMissing(into:)` repeats the repair for
    /// a user who deleted a preset and wants it back; it is not what keeps seeding correct.
    static func seed(into settings: inout Settings) {
        var existing = Set(settings.presets.map(\.id))
        for language in PromptLanguage.allCases
        where !settings.seededPromptLanguages.contains(language.code) {
            let seeded = presets(for: language)
            // A language with no content is not "seeded": marking it so would permanently
            // suppress its presets once the content arrives.
            guard !seeded.isEmpty else { continue }
            // Which kinds already have a default has to be read *before* adding anything:
            // `addPreset` claims the default whenever there is none, which would otherwise hand
            // it to whichever preset happened to be missing — on a pre-branch document that is
            // "Translate & organize", the one role that did not exist yet.
            let claimed = PresetKind.allCases.filter {
                settings.defaultPresetID(for: $0, language: language.code) != nil
            }
            for preset in seeded where !existing.contains(preset.id) {
                settings.addPreset(preset)
                existing.insert(preset.id)
            }
            for kind in PresetKind.allCases where !claimed.contains(kind) {
                guard let first = settings.presets(of: kind, language: language.code).first
                else { continue }
                settings.setDefaultPreset(id: first.id, for: kind, language: language.code)
            }
            settings.seededPromptLanguages.append(language.code)
        }
    }

    /// Re-adds factory presets the user deleted, in every language, and repairs a dangling
    /// default for every kind × language pair. Existing presets are never modified.
    ///
    /// Behind the "Restore factory presets" button, so it runs only on demand. `seed(into:)`
    /// above is the authority for a language being seeded; the `seededPromptLanguages` repair
    /// below is a belt-and-braces no-op for any document `seed` has already seen, kept only so
    /// this entry point cannot leave the key disagreeing with the presets it just restored.
    static func restoreMissing(into settings: inout Settings) {
        let existing = Set(settings.presets.map(\.id))
        for factory in all() where !existing.contains(factory.id) { settings.addPreset(factory) }
        for language in PromptLanguage.allCases {
            // A language only counts as seeded once it actually holds presets: marking an
            // empty language seeded would suppress its content forever.
            let hasPresets = PresetKind.allCases.contains {
                !settings.presets(of: $0, language: language.code).isEmpty
            }
            if hasPresets, !settings.seededPromptLanguages.contains(language.code) {
                settings.seededPromptLanguages.append(language.code)
            }
            for kind in PresetKind.allCases {
                let current = settings.defaultPresetID(for: kind, language: language.code)
                if current == nil || settings.preset(id: current!) == nil,
                   let first = settings.presets(of: kind, language: language.code).first {
                    settings.setDefaultPreset(id: first.id, for: kind, language: language.code)
                }
            }
        }
    }
}
