import Foundation
import Testing
@testable import Macomprendo

@Suite struct LanguageSegmenterTests {
    // 52 Cyrillic characters including the trailing ". ", then 41 Latin ones.
    private let mixed = "Это довольно длинное русское предложение для теста. "
        + "Now a long English sentence follows here."

    @Test func emptyTextHasNoRuns() {
        #expect(LanguageSegmenter.runs(in: "", minRunLength: 1).isEmpty)
    }

    @Test func singleScriptTextIsOneRun() {
        let runs = LanguageSegmenter.runs(in: "Hello there, friend.", minRunLength: 1)
        #expect(runs == [TextRun(text: "Hello there, friend.", script: .latin)])
    }

    @Test func neutralCharactersAttachToThePrecedingRun() {
        let runs = LanguageSegmenter.runs(in: "Привет, world!", minRunLength: 1)
        #expect(runs == [TextRun(text: "Привет, ", script: .cyrillic),
                         TextRun(text: "world!", script: .latin)])
    }

    @Test func leadingNeutralCharactersAttachToTheFollowingRun() {
        let runs = LanguageSegmenter.runs(in: "  — Привет", minRunLength: 1)
        #expect(runs == [TextRun(text: "  — Привет", script: .cyrillic)])
    }

    @Test func textWithoutLettersIsOneNeutralRun() {
        let runs = LanguageSegmenter.runs(in: "123 456 …", minRunLength: 1)
        #expect(runs == [TextRun(text: "123 456 …", script: .neutral)])
    }

    @Test func unknownScriptsAreNeutralAndNeverFlipTheVoice() {
        #expect(LanguageSegmenter.script(of: "世" as Character) == .neutral)
        #expect(LanguageSegmenter.script(of: "ع" as Character) == .neutral)
        let runs = LanguageSegmenter.runs(in: "Hello 世界 there", minRunLength: 1)
        #expect(runs == [TextRun(text: "Hello 世界 there", script: .latin)])
    }

    @Test func aShortForeignWordMergesIntoItsNeighbour() {
        // "Zoom" is 4 letters, under the default minimum of 6, so it merges into the
        // surrounding Cyrillic run instead of getting its own brief voice switch.
        let runs = LanguageSegmenter.runs(in: "Я купил новый Zoom вчера в магазине рядом с домом.")
        #expect(runs.count == 1)
        #expect(runs[0].script == .cyrillic)
        #expect(runs[0].text == "Я купил новый Zoom вчера в магазине рядом с домом.")
    }

    @Test func aLatinRunAtExactlyTheMinimumStaysSeparate() {
        // "iPhone" is exactly 6 letters — not *fewer than* the default minimum of 6 — so it
        // keeps its own Latin run instead of merging, unlike the shorter "Zoom" above.
        let runs = LanguageSegmenter.runs(in: "Я купил новый iPhone вчера в магазине рядом с домом.")
        #expect(runs.map(\.script) == [.cyrillic, .latin, .cyrillic])
        #expect(runs[0].text == "Я купил новый ")
        #expect(runs[1].text == "iPhone ")
        #expect(runs[2].text == "вчера в магазине рядом с домом.")
    }

    @Test func bothScriptsSurviveWhenEachRunIsLongEnough() {
        let runs = LanguageSegmenter.runs(in: mixed)
        #expect(runs.map(\.script) == [.cyrillic, .latin])
        #expect(runs[0].text == "Это довольно длинное русское предложение для теста. ")
        #expect(runs[1].text == "Now a long English sentence follows here.")
    }

    @Test func aShortLatinRunMergesIntoItsCyrillicNeighbour() {
        // "Привет, " has 6 Cyrillic letters; "world!" has 5 Latin letters, under the
        // default minimum of 6, so it merges into the Cyrillic run. Cyrillic runs are
        // never merge candidates regardless of length — only the Latin side's letter
        // count decides.
        let runs = LanguageSegmenter.runs(in: "Привет, world!")
        #expect(runs == [TextRun(text: "Привет, world!", script: .cyrillic)])
    }

    @Test func aCyrillicRunNeverMergesIntoALatinNeighbourNoMatterHowShort() {
        // A single Cyrillic letter ("я" is 1 letter, far under the minimum) still gets its
        // own run: Cyrillic never absorbs into Latin, because an English voice reading
        // Cyrillic collapses into letter-spelling while a Russian voice reading Latin is
        // merely accented. Both Latin words are deliberately at/above the minimum (7 and 6
        // letters) so this isolates rule 2 from rule 1 — nothing here merges because it is
        // short on the Latin side.
        let runs = LanguageSegmenter.runs(in: "Testing я typing")
        #expect(runs.map(\.script) == [.latin, .cyrillic, .latin])
        #expect(runs[0].text == "Testing ")
        #expect(runs[1].text == "я ")
        #expect(runs[2].text == "typing")
    }

    @Test func neutralAttachmentsNeverInfluenceTheLetterCountComparison() {
        // "swift 538/538, node 38/38), worktree" has 17 letters (well over the minimum) but
        // 37 characters including digits and punctuation — the merge decision must use the
        // letter count, not the character count, or this run would wrongly look short.
        let text = "Смержено и запущено. Merge-коммит 08c591c в main, тесты на смерженном " +
            "результате зелёные (swift 538/538, node 38/38), worktree и ветка удалены."
        let runs = LanguageSegmenter.runs(in: text)
        #expect(runs.map(\.script) == [.cyrillic, .latin, .cyrillic])
        #expect(runs[0].text == "Смержено и запущено. Merge-коммит 08c591c в main, тесты на " +
                "смерженном результате зелёные (")
        #expect(runs[1].text == "swift 538/538, node 38/38), worktree ")
        #expect(runs[2].text == "и ветка удалены.")
    }

    @Test func aTrailingNeutralDoesNotFlipTheScriptSplit() {
        // Same Cyrillic head + Latin tail split whether or not a trailing neutral run of
        // punctuation/space follows the Latin word — a trailing neutral must not tip the
        // Latin run's letter count or otherwise change which run it joins.
        let withTrailingNeutral = LanguageSegmenter.runs(in: "Источник «Endpoint» (")
        let withoutTrailingNeutral = LanguageSegmenter.runs(in: "Источник «Endpoint»")
        #expect(withTrailingNeutral == [TextRun(text: "Источник «", script: .cyrillic),
                                         TextRun(text: "Endpoint» (", script: .latin)])
        #expect(withoutTrailingNeutral == [TextRun(text: "Источник «", script: .cyrillic),
                                            TextRun(text: "Endpoint»", script: .latin)])
    }

    @Test func aCyrillicHeadStaysItsOwnRunAheadOfALongLatinRemainder() {
        let text = "Источник «Endpoint» (Settings ▸ Speech ▸ Speech source = Endpoint):"
        let runs = LanguageSegmenter.runs(in: text)
        #expect(runs == [TextRun(text: "Источник «", script: .cyrillic),
                         TextRun(text: "Endpoint» (Settings ▸ Speech ▸ Speech source = Endpoint):",
                                 script: .latin)])
    }

    @Test func aSevenLetterLatinRunStaysLatinInEitherWordOrder() {
        // "Base URL" is 7 letters, at or above the default minimum, so it keeps its own
        // Latin run whether it comes after or before the Cyrillic word.
        let cyrillicFirst = LanguageSegmenter.runs(in: "невалидный Base URL")
        let latinFirst = LanguageSegmenter.runs(in: "Base URL невалидный")
        #expect(cyrillicFirst == [TextRun(text: "невалидный ", script: .cyrillic),
                                   TextRun(text: "Base URL", script: .latin)])
        #expect(latinFirst == [TextRun(text: "Base URL ", script: .latin),
                                TextRun(text: "невалидный", script: .cyrillic)])
    }

    @Test func languageTagsAreClassifiedByTheirBaseCode() {
        #expect(LanguageSegmenter.script(ofLanguage: "ru-RU") == .cyrillic)
        #expect(LanguageSegmenter.script(ofLanguage: "uk-UA") == .cyrillic)
        #expect(LanguageSegmenter.script(ofLanguage: "en-US") == .latin)
        #expect(LanguageSegmenter.script(ofLanguage: "fr-CA") == .latin)
        #expect(LanguageSegmenter.script(ofLanguage: "zh-CN") == .neutral)
        #expect(LanguageSegmenter.script(ofLanguage: "") == .latin)
    }

    @Test func scalarClassificationSeparatesLettersFromEverythingElse() {
        #expect(LanguageSegmenter.script(of: "п" as Unicode.Scalar) == .cyrillic)
        #expect(LanguageSegmenter.script(of: "Z" as Unicode.Scalar) == .latin)
        #expect(LanguageSegmenter.script(of: "é" as Unicode.Scalar) == .latin)
        #expect(LanguageSegmenter.script(of: "7" as Unicode.Scalar) == .neutral)
        #expect(LanguageSegmenter.script(of: "×" as Unicode.Scalar) == .neutral)
        #expect(LanguageSegmenter.script(of: " " as Unicode.Scalar) == .neutral)
    }
}
