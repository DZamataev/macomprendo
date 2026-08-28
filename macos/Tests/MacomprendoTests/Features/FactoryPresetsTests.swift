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
        #expect(slots.count == 12)
        #expect(Set(slots).count == 12)
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
            #expect(presets.count == 12)
            for preset in presets {
                #expect(preset.language == language.code)
                #expect(preset.isFactory)
                #expect(PromptRenderer.validate(preset).isEmpty,
                        "\(language.code)/\(preset.name): \(PromptRenderer.validate(preset))")
                #expect(preset.userTemplate.contains("{text}"))
            }
        }
    }

    /// The OS language is only meaningful for plain Translate. Every other template either
    /// preserves the original language or names its target literally.
    @Test func onlyTranslateUsesTheLanguagePlaceholder() {
        for language in PromptLanguage.allCases {
            for role in FactoryPresets.Role.allCases {
                let template = language.content.entries[role]!.template
                #expect(template.contains("{language}") == (role == .translate),
                        "\(language.code)/\(role.rawValue)")
            }
        }
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

    @Test func rolesSplitEightRefineAndFourSummarize() {
        #expect(FactoryPresets.Role.allCases.filter { $0.kind == .refine }.count == 8)
        #expect(FactoryPresets.Role.allCases.filter { $0.kind == .summarize }.count == 4)
    }

    @Test func sortOrderRestartsAtZeroForEachKind() {
        let presets = FactoryPresets.presets(for: .english)
        #expect(presets.filter { $0.kind == .refine }.map(\.sortOrder) == Array(0..<8))
        #expect(presets.filter { $0.kind == .summarize }.map(\.sortOrder) == Array(0..<4))
    }

    @Test func seedFillsEveryLanguageOnceAndSetsPerLanguageDefaults() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        #expect(s.presets.count == 12 * PromptLanguage.allCases.count)
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
        #expect(s.presets.count == 12 * PromptLanguage.allCases.count)
    }
}
