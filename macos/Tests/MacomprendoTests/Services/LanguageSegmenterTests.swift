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
        let runs = LanguageSegmenter.runs(in: "Я купил новый iPhone вчера в магазине рядом с домом.")
        #expect(runs.count == 1)
        #expect(runs[0].script == .cyrillic)
        #expect(runs[0].text == "Я купил новый iPhone вчера в магазине рядом с домом.")
    }

    @Test func bothScriptsSurviveWhenEachRunIsLongEnough() {
        let runs = LanguageSegmenter.runs(in: mixed)
        #expect(runs.map(\.script) == [.cyrillic, .latin])
        #expect(runs[0].text == "Это довольно длинное русское предложение для теста. ")
        #expect(runs[1].text == "Now a long English sentence follows here.")
    }

    @Test func aShortRunTakesTheLongerNeighboursScript() {
        // "Привет, " is 8 characters, "world!" is 6: both are under the default minimum,
        // so they collapse into one run and the longer side (Cyrillic) wins the voice.
        let runs = LanguageSegmenter.runs(in: "Привет, world!")
        #expect(runs == [TextRun(text: "Привет, world!", script: .cyrillic)])
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
