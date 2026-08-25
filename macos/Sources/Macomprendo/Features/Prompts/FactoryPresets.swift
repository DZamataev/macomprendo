import Foundation

/// The presets shipped with the app. They are seeded once into `Settings.presets` and are
/// ordinary user data afterwards: editable, reorderable and deletable. The IDs are fixed so
/// `restoreMissing(into:)` can tell "deleted factory preset" from "custom preset".
enum FactoryPresets {
    static let systemPrompt = """
        You are a careful writing assistant. Process the user's text exactly as instructed. \
        Return only the resulting text — no commentary, no explanation, no quotation marks \
        around the output and no markdown code fences.
        """

    enum ID {
        static let cleanUp = UUID(uuidString: "F0000000-0000-0000-0000-000000000001")!
        static let formal = UUID(uuidString: "F0000000-0000-0000-0000-000000000002")!
        static let casual = UUID(uuidString: "F0000000-0000-0000-0000-000000000003")!
        static let shorten = UUID(uuidString: "F0000000-0000-0000-0000-000000000004")!
        static let expand = UUID(uuidString: "F0000000-0000-0000-0000-000000000005")!
        static let fixGrammar = UUID(uuidString: "F0000000-0000-0000-0000-000000000006")!
        static let translate = UUID(uuidString: "F0000000-0000-0000-0000-000000000007")!
        static let brief = UUID(uuidString: "F0000000-0000-0000-0000-000000000101")!
        static let bullets = UUID(uuidString: "F0000000-0000-0000-0000-000000000102")!
        static let tldr = UUID(uuidString: "F0000000-0000-0000-0000-000000000103")!
        static let keyActions = UUID(uuidString: "F0000000-0000-0000-0000-000000000104")!
    }

    static let defaultRefineID = ID.cleanUp
    static let defaultSummarizeID = ID.brief

    static func all() -> [PromptPreset] { refine() + summarize() }

    static func refine() -> [PromptPreset] {
        [
            make(ID.cleanUp, .refine, 0, "Clean up", """
                Clean up the following text. Remove filler words, false starts and stutters, and \
                fix punctuation and capitalization. Keep the meaning, the tone and the original language.
                {instruction}

                {text}
                """),
            make(ID.formal, .refine, 1, "Formal", """
                Rewrite the following text in a formal, professional register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            make(ID.casual, .refine, 2, "Casual", """
                Rewrite the following text in a relaxed, conversational register. Keep the meaning \
                and the original language.
                {instruction}

                {text}
                """),
            make(ID.shorten, .refine, 3, "Shorten", """
                Rewrite the following text so it is significantly shorter while keeping every \
                important point. Keep the original language.
                {instruction}

                {text}
                """),
            make(ID.expand, .refine, 4, "Expand", """
                Expand the following text with more detail and clearer structure. Do not invent \
                facts. Keep the original language.
                {instruction}

                {text}
                """),
            make(ID.fixGrammar, .refine, 5, "Fix grammar", """
                Correct spelling, grammar and punctuation in the following text. Change nothing \
                else — keep the wording, the tone and the original language.
                {instruction}

                {text}
                """),
            make(ID.translate, .refine, 6, "Translate", """
                Translate the following text into {language}. Preserve the tone and the formatting.
                {instruction}

                {text}
                """),
        ]
    }

    static func summarize() -> [PromptPreset] {
        [
            make(ID.brief, .summarize, 0, "Brief", """
                Summarize the following text in two or three sentences.
                {instruction}

                {text}
                """),
            make(ID.bullets, .summarize, 1, "Bullets", """
                Summarize the following text as at most six concise bullet points, one line each, \
                each starting with "- ".
                {instruction}

                {text}
                """),
            make(ID.tldr, .summarize, 2, "TL;DR", """
                Give a one-sentence TL;DR of the following text.
                {instruction}

                {text}
                """),
            make(ID.keyActions, .summarize, 3, "Key actions", """
                List the concrete action items in the following text as a numbered list. \
                If there are none, answer exactly "No action items."
                {instruction}

                {text}
                """),
        ]
    }

    /// First-run seeding. Does nothing once `presetsSeeded` is true.
    static func seed(into settings: inout Settings) {
        guard !settings.presetsSeeded else { return }
        settings.presets = all()
        settings.presetsSeeded = true
        settings.defaultRefinePresetID = defaultRefineID
        settings.defaultSummarizePresetID = defaultSummarizeID
    }

    /// Re-adds factory presets the user deleted, appended at the end of their kind.
    /// Existing presets — factory or custom — are never modified.
    static func restoreMissing(into settings: inout Settings) {
        let existing = Set(settings.presets.map(\.id))
        for factory in all() where !existing.contains(factory.id) {
            settings.addPreset(factory)
        }
        settings.presetsSeeded = true
        for kind in PresetKind.allCases {
            let current = settings.defaultPresetID(for: kind)
            if current == nil || settings.preset(id: current!) == nil,
               let first = settings.presets(of: kind).first {
                settings.setDefaultPreset(id: first.id, for: kind)
            }
        }
    }

    private static func make(_ id: UUID, _ kind: PresetKind, _ order: Int,
                             _ name: String, _ template: String) -> PromptPreset {
        PromptPreset(id: id, kind: kind, name: name, systemPrompt: systemPrompt,
                     userTemplate: template, isFactory: true, sortOrder: order)
    }
}
