import Foundation
import Testing
@testable import Macomprendo

@Suite struct FactoryPresetsTests {
    /// Every language must cover every role. `entries` is a dictionary, so this test is the
    /// thing that catches a forgotten role in a new content file.
    @Test func everyLanguageCoversEveryRole() {
        for language in PromptLanguage.allCases {
            let roles = Set(language.content.entries.keys)
            #expect(roles == Set(FactoryPresets.Role.allCases),
                    "\(language.code) is missing \(Set(FactoryPresets.Role.allCases).subtracting(roles))")
        }
    }

    @Test func roleSlotsAreTwelveHexDigitsAndUnique() {
        let slots = FactoryPresets.Role.allCases.map(\.slot)
        #expect(slots.count == 16)
        #expect(Set(slots).count == 16)
        #expect(slots.allSatisfy { $0.count == 12 && $0.allSatisfy(\.isHexDigit) })
    }

    @Test func englishIDsAreUnchangedFromTheShippedValues() {
        func id(_ role: FactoryPresets.Role) -> UUID {
            FactoryPresets.presetID(role: role, language: .english)
        }
        #expect(id(.cleanUp) == UUID(uuidString: "F0000000-0000-0000-0000-000000000001"))
        #expect(id(.formal) == UUID(uuidString: "F0000000-0000-0000-0000-000000000002"))
        #expect(id(.casual) == UUID(uuidString: "F0000000-0000-0000-0000-000000000003"))
        #expect(id(.shorten) == UUID(uuidString: "F0000000-0000-0000-0000-000000000004"))
        #expect(id(.expand) == UUID(uuidString: "F0000000-0000-0000-0000-000000000005"))
        #expect(id(.fixGrammar) == UUID(uuidString: "F0000000-0000-0000-0000-000000000006"))
        #expect(id(.translate) == UUID(uuidString: "F0000000-0000-0000-0000-000000000007"))
        #expect(id(.brief) == UUID(uuidString: "F0000000-0000-0000-0000-000000000101"))
        #expect(id(.bullets) == UUID(uuidString: "F0000000-0000-0000-0000-000000000102"))
        #expect(id(.tldr) == UUID(uuidString: "F0000000-0000-0000-0000-000000000103"))
        #expect(id(.keyActions) == UUID(uuidString: "F0000000-0000-0000-0000-000000000104"))
    }

    @Test func translateAndOrganizeIsTheOneNewEnglishID() {
        #expect(FactoryPresets.presetID(role: .translateAndOrganize, language: .english)
                == UUID(uuidString: "F0000000-0000-0000-0000-000000000008"))
    }

    @Test func idsAreUniqueAcrossTheWholeSet() {
        let ids = FactoryPresets.all().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyPresetIsValidAndCarriesItsLanguage() {
        for language in PromptLanguage.allCases {
            let presets = FactoryPresets.presets(for: language)
            #expect(presets.count == 16)
            for preset in presets {
                #expect(preset.language == language.code)
                #expect(preset.isFactory)
                #expect(PromptRenderer.validate(preset).isEmpty,
                        "\(language.code)/\(preset.name): \(PromptRenderer.validate(preset))")
                #expect(preset.userTemplate.contains("{text}"))
            }
        }
    }

    /// `{language}` is the OS language, so exactly the roles that promise to write in it may
    /// carry it. Every other template either preserves the original language or names its
    /// target literally, and `translatesToTheOSLanguage` is the single list both sides agree on.
    @Test func onlyTheTranslatingRolesUseTheLanguagePlaceholder() {
        for language in PromptLanguage.allCases {
            for role in FactoryPresets.Role.allCases {
                let template = language.content.entries[role]!.template
                #expect(template.contains("{language}") == role.translatesToTheOSLanguage,
                        "\(language.code)/\(role.rawValue)")
            }
        }
    }

    @Test func theTranslatingRolesAreTranslateAndTheFourSummarizeVariants() {
        #expect(Set(FactoryPresets.Role.allCases.filter(\.translatesToTheOSLanguage))
                == [.translate, .briefTranslated, .bulletsTranslated, .tldrTranslated,
                    .keyActionsTranslated])
    }

    @Test func everyTranslatedSetIsWrittenNativelyAndKeepsItsNames() {
        let expectedTranslateAndOrganize: [PromptLanguage: String] = [
            .russian: "Перевести и систематизировать",
            .spanish: "Traducir y organizar",
            .german: "Übersetzen und ordnen",
            .french: "Traduire et organiser",
            .portuguese: "Traduzir e organizar",
            .chinese: "翻译并整理"
        ]
        for (language, name) in expectedTranslateAndOrganize {
            let content = language.content
            #expect(content.systemPrompt != PromptLanguage.english.content.systemPrompt,
                    "\(language.code) still uses the English system prompt")
            #expect(content.entries[.translateAndOrganize]!.name == name)
            for role in FactoryPresets.Role.allCases {
                let english = PromptLanguage.english.content.entries[role]!.template
                #expect(content.entries[role]!.template != english,
                        "\(language.code)/\(role.rawValue) is still the English template")
            }
        }
    }

    @Test func everyTemplateKeepsThePlaceholderBlockVerbatim() {
        for language in PromptLanguage.allCases {
            for role in FactoryPresets.Role.allCases {
                let template = language.content.entries[role]!.template
                #expect(template.hasSuffix("{instruction}\n\n{text}"),
                        "\(language.code)/\(role.rawValue) does not end with the placeholder block")
            }
        }
    }

    @Test func rolesSplitEightRefineAndEightSummarize() {
        #expect(FactoryPresets.Role.allCases.filter { $0.kind == .refine }.count == 8)
        #expect(FactoryPresets.Role.allCases.filter { $0.kind == .summarize }.count == 8)
    }

    @Test func sortOrderRestartsAtZeroForEachKind() {
        let presets = FactoryPresets.presets(for: .english)
        #expect(presets.filter { $0.kind == .refine }.map(\.sortOrder) == Array(0..<8))
        #expect(presets.filter { $0.kind == .summarize }.map(\.sortOrder) == Array(0..<8))
    }

    @Test func seedFillsEveryLanguageOnceAndSetsPerLanguageDefaults() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        #expect(s.presets.count == 16 * PromptLanguage.allCases.count)
        #expect(s.seededPromptLanguages == PromptLanguage.allCases.map(\.code))
        for language in PromptLanguage.allCases {
            #expect(s.defaultPreset(for: .refine, language: language.code)?.id
                    == FactoryPresets.presetID(role: .cleanUp, language: language))
            #expect(s.defaultPreset(for: .summarize, language: language.code)?.id
                    == FactoryPresets.presetID(role: .brief, language: language))
        }
        let before = s
        FactoryPresets.seed(into: &s)
        #expect(s == before)
    }

    /// A document written by a build from before `seededPromptLanguages` existed already holds
    /// the English factory presets — they decode with `language == "en"` — but decodes the new
    /// key to `[]`. Seeding must notice the presets themselves, not only the key, or English is
    /// seeded a second time and every English ID exists twice.
    @Test func seedingADocumentThatAlreadyHoldsEnglishAddsNoDuplicates() {
        var s = Settings.default
        s.presets = FactoryPresets.presets(for: .english)
            .filter { $0.id != FactoryPresets.presetID(role: .translateAndOrganize,
                                                       language: .english) }
        s.seededPromptLanguages = []
        s.defaultPresetIDs = [:]

        FactoryPresets.seed(into: &s)

        let english = s.presets.filter { $0.language == "en" }
        #expect(Set(english.map(\.id)).count == english.count)
        #expect(english.count == FactoryPresets.Role.allCases.count)
        #expect(s.seededPromptLanguages.contains("en"))
        // The role that did not exist before this branch arrives without claiming the default
        // the pre-branch document never stored.
        #expect(s.preset(id: FactoryPresets.presetID(role: .translateAndOrganize,
                                                     language: .english)) != nil)
        #expect(s.defaultPreset(for: .refine, language: "en")?.id
                == FactoryPresets.presetID(role: .cleanUp, language: .english))
    }

    /// The partially-seeded case: the user deleted a few presets of a language whose key was
    /// then lost. Seeding must still not duplicate what is there.
    @Test func seedingALanguageThatHoldsSomeOfItsPresetsDuplicatesNothing() throws {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        try s.deletePreset(id: FactoryPresets.presetID(role: .casual, language: .russian))
        try s.deletePreset(id: FactoryPresets.presetID(role: .tldr, language: .russian))
        s.seededPromptLanguages = []
        let defaultsBefore = s.defaultPresetIDs

        FactoryPresets.seed(into: &s)

        let ids = s.presets.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(s.presets.count == 16 * PromptLanguage.allCases.count)
        // A default that was already stored is never re-pointed by seeding.
        #expect(s.defaultPresetIDs == defaultsBefore)
    }

    @Test func restoreMissingBringsBackADeletedFactoryPresetInItsOwnLanguage() throws {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        let victim = FactoryPresets.presetID(role: .bullets, language: .russian)
        try s.deletePreset(id: victim)
        #expect(s.preset(id: victim) == nil)
        FactoryPresets.restoreMissing(into: &s)
        #expect(s.preset(id: victim)?.language == "ru")
        #expect(s.presets.count == 16 * PromptLanguage.allCases.count)
    }
}

/// Adding a role to the factory set has to reach documents that were already seeded, without
/// resurrecting a factory preset the user deliberately deleted. `seededFactoryVersion` plus
/// `Role.introducedIn` is what separates those two cases.
@MainActor
@Suite struct FactorySetVersioningTests {
    /// A document as an older build left it: every language listed, but only the roles that
    /// existed at `version`. Built by seeding the current set and removing what came later,
    /// so it stays honest if roles are added again.
    private func seededAtVersion(_ version: Int) -> Settings {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        s.seededFactoryVersion = 0
        FactoryPresets.seed(into: &s)
        let laterRoles = FactoryPresets.Role.allCases.filter { $0.introducedIn > version }
        let stale = Set(PromptLanguage.allCases.flatMap { language in
            laterRoles.map { FactoryPresets.presetID(role: $0, language: language) }
        })
        s.presets.removeAll { stale.contains($0.id) }
        s.seededFactoryVersion = version
        return s
    }

    @Test func aFreshInstallRecordsTheCurrentFactoryVersion() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        s.seededFactoryVersion = 0
        FactoryPresets.seed(into: &s)
        #expect(s.seededFactoryVersion == FactoryPresets.currentVersion)
        #expect(s.presets.count == FactoryPresets.Role.allCases.count * PromptLanguage.allCases.count)
    }

    @Test func rolesAddedSinceTheRecordedVersionAreSeededIntoAnAlreadySeededDocument() {
        var s = seededAtVersion(0)
        let before = s.presets.count
        let newRoles = FactoryPresets.Role.allCases.filter { $0.introducedIn > 0 }
        #expect(!newRoles.isEmpty, "this test is vacuous unless some role is newer than version 0")
        #expect(before == (FactoryPresets.Role.allCases.count - newRoles.count) * PromptLanguage.allCases.count)

        FactoryPresets.seed(into: &s)

        #expect(s.seededFactoryVersion == FactoryPresets.currentVersion)
        #expect(s.presets.count == FactoryPresets.Role.allCases.count * PromptLanguage.allCases.count)
        for language in PromptLanguage.allCases {
            for role in newRoles {
                #expect(s.preset(id: FactoryPresets.presetID(role: role, language: language)) != nil,
                        "\(language.code)/\(role.rawValue) was not topped up")
            }
        }
    }

    @Test func aDeletedOlderPresetIsNotResurrectedByTheTopUp() throws {
        var s = seededAtVersion(0)
        let victim = FactoryPresets.presetID(role: .bullets, language: .russian)
        try s.deletePreset(id: victim)
        FactoryPresets.seed(into: &s)
        #expect(s.preset(id: victim) == nil, "the top-up must not undo a deliberate deletion")
        #expect(s.preset(id: FactoryPresets.presetID(role: .briefTranslated, language: .russian)) != nil)
    }

    @Test func theTopUpIsIdempotent() {
        var s = seededAtVersion(0)
        FactoryPresets.seed(into: &s)
        let after = s
        FactoryPresets.seed(into: &s)
        #expect(s == after)
    }

    @Test func theTopUpLeavesTheChosenDefaultsAlone() {
        var s = seededAtVersion(0)
        let chosen = FactoryPresets.presetID(role: .tldr, language: .german)
        s.setDefaultPreset(id: chosen, for: .summarize, language: "de")
        FactoryPresets.seed(into: &s)
        #expect(s.defaultPresetID(for: .summarize, language: "de") == chosen)
    }
}
