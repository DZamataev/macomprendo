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
        #expect(s.presets(of: .refine).map(\.name) == ["a", "b"])
        #expect(s.presets(of: .summarize).map(\.name) == ["z"])
    }

    @Test func addPresetAppendsAtEndOfItsKindAndBecomesDefaultWhenFirst() {
        var s = Settings.default
        s.presets = []
        s.defaultRefinePresetID = nil
        let first = s.addPreset(preset("first", .refine, 99))
        #expect(first.sortOrder == 0)
        #expect(s.defaultRefinePresetID == first.id)
        let second = s.addPreset(preset("second", .refine, 99))
        #expect(second.sortOrder == 1)
        #expect(s.defaultRefinePresetID == first.id)
    }

    @Test func defaultPresetFallsBackToFirstOfKind() {
        var s = Settings.default
        let a = preset("a", .refine, 0)
        s.presets = [a]
        s.defaultRefinePresetID = UUID()          // dangling
        #expect(s.defaultPreset(for: .refine)?.id == a.id)
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
        s.defaultRefinePresetID = a.id
        try s.deletePreset(id: a.id)
        #expect(s.defaultRefinePresetID == b.id)
        #expect(s.presets(of: .refine).map(\.name) == ["b"])
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
        #expect(s.presets(of: .refine).map(\.name) == ["c", "a", "b"])
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
