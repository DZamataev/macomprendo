import Foundation
import Testing
@testable import Macomprendo

@Suite struct PromptLanguageTests {
    @Test func codesAndSlotsAreFrozenInOrder() {
        #expect(PromptLanguage.allCases.map(\.code) == ["en", "ru", "es", "de", "fr", "pt", "zh"])
        #expect(PromptLanguage.allCases.map(\.slot) == ["0000", "0001", "0002", "0003", "0004", "0005", "0006"])
    }

    @Test func slotsAreFourHexDigitsAndUnique() {
        let slots = PromptLanguage.allCases.map(\.slot)
        #expect(Set(slots).count == slots.count)
        #expect(slots.allSatisfy { $0.count == 4 && $0.allSatisfy(\.isHexDigit) })
    }

    @Test func displayNamesAreEndonyms() {
        #expect(PromptLanguage.allCases.map(\.displayName)
                == ["English", "Русский", "Español", "Deutsch", "Français", "Português", "中文"])
    }

    @Test func namedResolvesKnownCodesOnly() {
        #expect(PromptLanguage.named("ru") == .russian)
        #expect(PromptLanguage.named("zh") == .chinese)
        #expect(PromptLanguage.named("ru-RU") == nil)
        #expect(PromptLanguage.named("uk") == nil)
    }

    @Test func systemDefaultIsAlwaysOneOfTheSeven() {
        #expect(PromptLanguage.allCases.contains(PromptLanguage.systemDefault))
    }

    @Test func resolvingALocaleFallsBackToEnglish() {
        #expect(PromptLanguage.resolve(languageCode: "de") == .german)
        #expect(PromptLanguage.resolve(languageCode: "uk") == .english)
        #expect(PromptLanguage.resolve(languageCode: nil) == .english)
    }
}
