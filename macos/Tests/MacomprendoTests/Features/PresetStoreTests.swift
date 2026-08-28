import Foundation
import Testing
@testable import Macomprendo

@Suite struct PresetStoreTests {
    private func preset(_ name: String, _ kind: PresetKind, _ order: Int) -> PromptPreset {
        PromptPreset(id: UUID(), kind: kind, name: name, systemPrompt: "sys",
                     userTemplate: "{text}", isFactory: false, sortOrder: order)
    }

    @Test func presetsOfKindAreSortedBySortOrder() {
        var s = Settings.default
        let b = preset("b", .refine, 1), a = preset("a", .refine, 0), z = preset("z", .summarize, 0)
        s.presets = [b, z, a]
        #expect(s.presets(of: .refine, language: "en").map(\.name) == ["a", "b"])
        #expect(s.presets(of: .summarize, language: "en").map(\.name) == ["z"])
    }

    @Test func addPresetAppendsAtEndOfItsKindAndBecomesDefaultWhenFirst() {
        var s = Settings.default
        s.presets = []
        s.defaultPresetIDs[Settings.presetKey(.refine, "en")] = nil
        let first = s.addPreset(preset("first", .refine, 99))
        #expect(first.sortOrder == 0)
        #expect(s.defaultPresetID(for: .refine, language: "en") == first.id)
        let second = s.addPreset(preset("second", .refine, 99))
        #expect(second.sortOrder == 1)
        #expect(s.defaultPresetID(for: .refine, language: "en") == first.id)
    }

    @Test func defaultPresetFallsBackToFirstOfKind() {
        var s = Settings.default
        let a = preset("a", .refine, 0)
        s.presets = [a]
        s.defaultPresetIDs[Settings.presetKey(.refine, "en")] = UUID()          // dangling
        #expect(s.defaultPreset(for: .refine, language: "en")?.id == a.id)
    }

    @Test func deletingTheLastPresetOfAKindIsRefused() {
        var s = Settings.default
        let only = preset("only", .refine, 0)
        s.presets = [only]
        #expect(throws: PresetError.lastOfKind(.refine)) { try s.deletePreset(id: only.id) }
        #expect(s.presets.count == 1)
    }

    @Test func deletingTheDefaultMovesDefaultToFirstRemaining() throws {
        var s = Settings.default
        let a = preset("a", .refine, 0), b = preset("b", .refine, 1)
        s.presets = [a, b]
        s.defaultPresetIDs[Settings.presetKey(.refine, "en")] = a.id
        try s.deletePreset(id: a.id)
        #expect(s.defaultPresetID(for: .refine, language: "en") == b.id)
        #expect(s.presets(of: .refine, language: "en").map(\.name) == ["b"])
    }

    @Test func deletingAnUnknownIDThrowsNotFound() {
        var s = Settings.default
        s.presets = [preset("a", .refine, 0), preset("b", .refine, 1)]
        #expect(throws: PresetError.notFound) { try s.deletePreset(id: UUID()) }
    }

    @Test func movePresetRenumbersOnlyItsOwnKind() {
        var s = Settings.default
        let a = preset("a", .refine, 0), b = preset("b", .refine, 1), c = preset("c", .refine, 2)
        let keep = preset("keep", .summarize, 7)
        s.presets = [a, b, c, keep]
        s.movePreset(id: c.id, to: 0)
        #expect(s.presets(of: .refine, language: "en").map(\.name) == ["c", "a", "b"])
        #expect(s.preset(id: keep.id)?.sortOrder == 7)
    }

    @Test func updatePresetReplacesByID() {
        var s = Settings.default
        var a = preset("a", .refine, 0)
        s.presets = [a]
        a.name = "renamed"
        s.updatePreset(a)
        #expect(s.preset(id: a.id)?.name == "renamed")
    }
}

@Suite struct LanguageAwarePresetStoreTests {
    private func preset(_ kind: PresetKind, _ language: String, _ name: String) -> PromptPreset {
        PromptPreset(kind: kind, language: language, name: name, systemPrompt: "s",
                     userTemplate: "{text}", isFactory: false, sortOrder: 0)
    }

    @Test func presetsAreFilteredByKindAndLanguage() {
        var s = Settings.default
        s.presets = []
        s.addPreset(preset(.refine, "en", "A"))
        s.addPreset(preset(.refine, "ru", "Б"))
        s.addPreset(preset(.summarize, "ru", "В"))
        #expect(s.presets(of: .refine, language: "en").map(\.name) == ["A"])
        #expect(s.presets(of: .refine, language: "ru").map(\.name) == ["Б"])
        #expect(s.presets(of: .summarize, language: "ru").map(\.name) == ["В"])
        #expect(s.presets(of: .summarize, language: "en").isEmpty)
    }

    @Test func sortOrderIsNumberedWithinOneKindAndLanguage() {
        var s = Settings.default
        s.presets = []
        let first = s.addPreset(preset(.refine, "ru", "1"))
        let second = s.addPreset(preset(.refine, "ru", "2"))
        let other = s.addPreset(preset(.refine, "en", "x"))
        #expect(first.sortOrder == 0)
        #expect(second.sortOrder == 1)
        #expect(other.sortOrder == 0)
    }

    @Test func eachKindAndLanguageKeepsItsOwnDefault() {
        var s = Settings.default
        s.presets = []
        let en = s.addPreset(preset(.refine, "en", "A"))
        let ru = s.addPreset(preset(.refine, "ru", "Б"))
        #expect(s.defaultPreset(for: .refine, language: "en")?.id == en.id)
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == ru.id)
        let second = s.addPreset(preset(.refine, "ru", "Г"))
        s.setDefaultPreset(id: second.id, for: .refine, language: "ru")
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == second.id)
        #expect(s.defaultPreset(for: .refine, language: "en")?.id == en.id)
    }

    @Test func aDanglingDefaultFallsBackToTheFirstOfThatLanguage() {
        var s = Settings.default
        s.presets = []
        let first = s.addPreset(preset(.refine, "ru", "Б"))
        s.defaultPresetIDs[Settings.presetKey(.refine, "ru")] = UUID()
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == first.id)
    }

    @Test func theLastPresetOfAKindAndLanguageCannotBeDeleted() {
        var s = Settings.default
        s.presets = []
        let only = s.addPreset(preset(.refine, "ru", "Б"))
        s.addPreset(preset(.refine, "en", "A"))
        #expect(throws: PresetError.lastOfKind(.refine)) { try s.deletePreset(id: only.id) }
    }

    @Test func deletingTheDefaultPromotesTheNextOfTheSameLanguage() throws {
        var s = Settings.default
        s.presets = []
        let first = s.addPreset(preset(.refine, "ru", "Б"))
        let second = s.addPreset(preset(.refine, "ru", "Г"))
        try s.deletePreset(id: first.id)
        #expect(s.defaultPreset(for: .refine, language: "ru")?.id == second.id)
    }

    @Test func movingReordersOnlyWithinOneLanguage() {
        var s = Settings.default
        s.presets = []
        let a = s.addPreset(preset(.refine, "ru", "1"))
        let b = s.addPreset(preset(.refine, "ru", "2"))
        let en = s.addPreset(preset(.refine, "en", "x"))
        s.movePreset(id: b.id, to: 0)
        #expect(s.presets(of: .refine, language: "ru").map(\.id) == [b.id, a.id])
        #expect(s.preset(id: en.id)?.sortOrder == 0)
    }
}
