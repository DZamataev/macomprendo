import Foundation
import Testing
@testable import Macomprendo

@Suite struct LanguageDetectorTests {
    private let detector = NLLanguageDetector()

    @Test func detectsABaseCodeForAConfidentSample() {
        #expect(detector.dominantLanguage(of: "Это довольно длинное русское предложение.") == "ru")
        #expect(detector.dominantLanguage(of: "This is a reasonably long English sentence.") == "en")
        #expect(detector.dominantLanguage(of: "Dies ist ein ziemlich langer deutscher Satz.") == "de")
    }

    /// NLLanguage uses script-qualified tags for Chinese ("zh-Hans"); the map is keyed by base
    /// codes, so the region and script are stripped.
    @Test func stripsTheScriptOrRegionSubtag() {
        let language = detector.dominantLanguage(of: "这是一个相当长的中文句子。")
        #expect(language == "zh")
    }

    @Test func returnsNilForTextWithNoLanguage() {
        #expect(detector.dominantLanguage(of: "") == nil)
        #expect(detector.dominantLanguage(of: "12345 67890") == nil)
    }
}

@Suite struct LetterCountTests {
    @Test func countsOnlyCyrillicAndLatinLetters() {
        #expect(LanguageSegmenter.letterCount("(swift 538/538, node 38/38)") == 9)
        #expect(LanguageSegmenter.letterCount("Привет, мир!") == 9)
        #expect(LanguageSegmenter.letterCount("123 …") == 0)
    }
}
