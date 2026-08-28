import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranslationTargetTests {
    @Test func theListCoversTheSevenPromptLanguagesAndMore() {
        let codes = Set(TranslationLanguages.options.map(\.code))
        for language in PromptLanguage.allCases {
            #expect(codes.contains(language.code),
                    "\(language.code) has a prompt set but cannot be a translation target")
        }
        #expect(codes.count > PromptLanguage.allCases.count,
                "the point of a separate list is translating into languages we ship no prompts for")
        #expect(codes.count == TranslationLanguages.options.count, "duplicate codes")
    }

    @Test func everyOptionHasANameAndTheLookupAgrees() {
        for option in TranslationLanguages.options {
            #expect(!option.name.isEmpty)
            #expect(TranslationLanguages.name(for: option.code) == option.name)
        }
        #expect(TranslationLanguages.name(for: "xx") == nil)
    }

    /// The name is what lands in `{chosen_language}`, so it is written in English regardless of
    /// which language's prompt set is showing: the placeholder sits on its own "target language"
    /// line, where a proper name reads correctly in any of the seven.
    @Test func aFixedTargetResolvesToThatLanguagesName() {
        let target = TranslationTarget.fixed("ja")
        #expect(target.resolvedName(promptLanguage: "ru", systemLanguageCode: "de") == "Japanese")
    }

    @Test func theSystemTargetFollowsTheOSAndIgnoresThePromptLanguage() {
        let target = TranslationTarget.systemLanguage
        #expect(target.resolvedName(promptLanguage: "ru", systemLanguageCode: "de") == "German")
        #expect(target.resolvedName(promptLanguage: "ru", systemLanguageCode: "en") == "English")
    }

    @Test func thePromptTargetFollowsTheShownPromptSet() {
        let target = TranslationTarget.promptLanguage
        #expect(target.resolvedName(promptLanguage: "ru", systemLanguageCode: "en") == "Russian")
        #expect(target.resolvedName(promptLanguage: "zh", systemLanguageCode: "en") == "Chinese")
    }

    /// An OS language we ship no name for, or a stored code from a list that later shrank, must
    /// still produce a usable prompt rather than an empty target line.
    @Test func anUnknownLanguageFallsBackToEnglish() {
        #expect(TranslationTarget.systemLanguage
            .resolvedName(promptLanguage: "ru", systemLanguageCode: "sw") == "English")
        #expect(TranslationTarget.systemLanguage
            .resolvedName(promptLanguage: "ru", systemLanguageCode: nil) == "English")
        #expect(TranslationTarget.fixed("xx")
            .resolvedName(promptLanguage: "ru", systemLanguageCode: "de") == "English")
        #expect(TranslationTarget.promptLanguage
            .resolvedName(promptLanguage: "xx", systemLanguageCode: "de") == "English")
    }

    @Test func everyTargetSurvivesARoundTrip() throws {
        for target in [TranslationTarget.systemLanguage, .promptLanguage, .fixed("pt")] {
            let data = try JSONEncoder().encode(target)
            #expect(try JSONDecoder().decode(TranslationTarget.self, from: data) == target)
        }
    }

    /// The picker names the OS option with what it currently resolves to, so the user can see
    /// which language "follow the system" actually means on this Mac.
    @Test func theSystemOptionIsLabelledWithTheLanguageItResolvesTo() {
        #expect(TranslationTarget.systemLanguage.pickerLabel(promptLanguage: "ru",
                                                             systemLanguageCode: "de")
                == "System language (German)")
        #expect(TranslationTarget.promptLanguage.pickerLabel(promptLanguage: "ru",
                                                             systemLanguageCode: "de")
                == "Prompt language")
        #expect(TranslationTarget.fixed("ja").pickerLabel(promptLanguage: "ru",
                                                          systemLanguageCode: "de")
                == "Japanese")
    }
}
