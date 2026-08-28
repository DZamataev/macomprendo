import Foundation
import Testing
@testable import Macomprendo

@Suite struct FactoryPresetsTests {
    @Test func allContainsSevenRefineAndFourSummarizePresets() {
        #expect(FactoryPresets.refine().count == 7)
        #expect(FactoryPresets.summarize().count == 4)
        #expect(FactoryPresets.all().count == 11)
        #expect(FactoryPresets.refine().allSatisfy { $0.kind == .refine && $0.isFactory })
        #expect(FactoryPresets.summarize().allSatisfy { $0.kind == .summarize && $0.isFactory })
    }

    @Test func namesMatchTheSpec() {
        #expect(FactoryPresets.refine().map(\.name)
                == ["Clean up", "Formal", "Casual", "Shorten", "Expand", "Fix grammar", "Translate"])
        #expect(FactoryPresets.summarize().map(\.name)
                == ["Brief", "Bullets", "TL;DR", "Key actions"])
    }

    @Test func everyFactoryTemplateContainsTextPlaceholderAndTranslateUsesLanguage() {
        #expect(FactoryPresets.all().allSatisfy { $0.userTemplate.contains("{text}") })
        let translate = FactoryPresets.all().first { $0.id == FactoryPresets.ID.translate }
        #expect(translate?.userTemplate.contains("{language}") == true)
    }

    @Test func idsAreStableAcrossCalls() {
        #expect(FactoryPresets.all().map(\.id) == FactoryPresets.all().map(\.id))
        #expect(FactoryPresets.all().first?.id == FactoryPresets.ID.cleanUp)
    }

    @Test func seedOnlyRunsOnceAndSetsDefaults() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        #expect(s.presets.count == 11)
        #expect(s.seededPromptLanguages.contains("en"))
        #expect(s.defaultPresetID(for: .refine, language: "en") == FactoryPresets.ID.cleanUp)
        #expect(s.defaultPresetID(for: .summarize, language: "en") == FactoryPresets.ID.brief)

        s.presets.removeAll { $0.id == FactoryPresets.ID.formal }
        FactoryPresets.seed(into: &s)                 // second call is a no-op
        #expect(s.presets.count == 10)
    }

    @Test func restoreMissingReaddsFactoryPresetsWithoutTouchingCustomOnes() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        let custom = s.addPreset(PromptPreset(id: UUID(), kind: .refine, language: "en", name: "Mine",
                                              systemPrompt: "s", userTemplate: "{text}",
                                              isFactory: false, sortOrder: 0))
        s.presets.removeAll { $0.id == FactoryPresets.ID.casual }
        s.presets.removeAll { $0.id == FactoryPresets.ID.tldr }

        FactoryPresets.restoreMissing(into: &s)

        #expect(s.preset(id: FactoryPresets.ID.casual) != nil)
        #expect(s.preset(id: FactoryPresets.ID.tldr) != nil)
        #expect(s.preset(id: custom.id)?.name == "Mine")
        #expect(s.presets.filter { $0.id == custom.id }.count == 1)
        #expect(s.presets(of: .refine, language: "en").last?.id == FactoryPresets.ID.casual)   // appended at the end
    }

    @Test func restoreMissingRepairsADanglingDefault() {
        var s = Settings.default
        s.presets = []
        s.seededPromptLanguages = []
        FactoryPresets.seed(into: &s)
        s.defaultPresetIDs[Settings.presetKey(.refine, "en")] = UUID()
        FactoryPresets.restoreMissing(into: &s)
        #expect(s.defaultPresetID(for: .refine, language: "en") == FactoryPresets.ID.cleanUp)
    }
}
