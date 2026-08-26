import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechSegmentationTests {
    private let voices = [
        Voice(id: "en.alex", name: "Alex", language: "en-US", quality: "default"),
        Voice(id: "en.ava.premium", name: "Ava", language: "en-US", quality: "premium"),
        Voice(id: "en.daniel", name: "Daniel", language: "en-GB", quality: "enhanced"),
        Voice(id: "ru.milena", name: "Milena", language: "ru-RU", quality: "default"),
        Voice(id: "ru.milena.enhanced", name: "Milena", language: "ru-RU", quality: "enhanced"),
        Voice(id: "uk.lesya", name: "Lesya", language: "uk-UA", quality: "premium"),
        Voice(id: "zh.tingting", name: "Tingting", language: "zh-CN", quality: "premium")
    ]

    private let cyrillicPart = "Это довольно длинное русское предложение для теста. "
    private let latinPart = "Now a long English sentence follows here."

    private func settings(_ voiceID: String?) -> SpeechSettings {
        SpeechSettings(voiceID: voiceID, rate: 0.5, pitch: 1, volume: 1)
    }

    // MARK: fallbackVoice

    @Test func cyrillicFallbackPrefersRussianThenQuality() {
        #expect(AVSpeechService.fallbackVoice(for: .cyrillic, in: voices)?.id == "ru.milena.enhanced")
    }

    @Test func latinFallbackPrefersEnglishThenQuality() {
        #expect(AVSpeechService.fallbackVoice(for: .latin, in: voices)?.id == "en.ava.premium")
    }

    @Test func neutralRunsHaveNoFallbackVoice() {
        #expect(AVSpeechService.fallbackVoice(for: .neutral, in: voices) == nil)
    }

    @Test func anEmptyVoiceListHasNoFallbackVoice() {
        #expect(AVSpeechService.fallbackVoice(for: .latin, in: []) == nil)
        #expect(AVSpeechService.fallbackVoice(for: .cyrillic, in: []) == nil)
    }

    @Test func voicesInOtherScriptsAreNeverAFallback() {
        let onlyChinese = [Voice(id: "zh.tingting", name: "Tingting", language: "zh-CN", quality: "premium")]
        #expect(AVSpeechService.fallbackVoice(for: .latin, in: onlyChinese) == nil)
        // A Ukrainian voice is a valid Cyrillic fallback when no Russian one is installed.
        let onlyUkrainian = [Voice(id: "uk.lesya", name: "Lesya", language: "uk-UA", quality: "premium")]
        #expect(AVSpeechService.fallbackVoice(for: .cyrillic, in: onlyUkrainian)?.id == "uk.lesya")
    }

    // MARK: utterancePlan

    @Test func singleScriptTextStaysOneUtterance() {
        let plan = AVSpeechService.utterancePlan(text: latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: latinPart, voiceID: "en.alex")])
    }

    @Test func mixedScriptTextSwitchesVoicePerRun() {
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: latinPart, voiceID: "en.alex")])
    }

    @Test func aMissingFallbackVoiceKeepsTheConfiguredVoice() {
        let englishOnly = voices.filter { $0.language.hasPrefix("en") }
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: englishOnly)
        #expect(plan.map(\.voiceID) == ["en.alex", "en.alex"])
        #expect(plan.map(\.text) == [cyrillicPart, latinPart])
    }

    @Test func textIsSplitEvenWhenNoVoiceIsConfigured() {
        // No configured voice means the configured script is assumed Latin.
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings(nil),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: latinPart, voiceID: nil)])
    }

    @Test func aSingleRunInTheWrongScriptStillSwitchesVoice() {
        // Wholly-Cyrillic text with no Latin run at all: the spec's algorithm has no
        // single-run exemption, so this must still switch to the Cyrillic fallback voice
        // instead of mangling the text under the configured English voice.
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced")])
    }

    @Test func aSingleForeignWordDoesNotSplitTheUtterance() {
        // "Zoom" is 4 letters, under the default minimum of 6, so it merges into the
        // Cyrillic run and the whole sentence stays one utterance.
        let text = "Я купил новый Zoom вчера в магазине рядом с домом."
        let plan = AVSpeechService.utterancePlan(text: text,
                                                 settings: settings("ru.milena"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: text, voiceID: "ru.milena")])
    }

    @Test func neutralOnlyTextStaysOneUtterance() {
        let plan = AVSpeechService.utterancePlan(text: "123 456 …",
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: "123 456 …", voiceID: "en.alex")])
    }

    @Test func aCyrillicHeadSwitchesToTheRussianFallbackAheadOfALongLatinTail() {
        // Real-world case: "Источник «Endpoint» (…)" with an English configured voice.
        // The Cyrillic head ("Источник «") is short but never merges into Latin (rule 2),
        // so it gets its own utterance on the Russian fallback voice; the long Latin
        // remainder stays on the configured English voice.
        let text = "Источник «Endpoint» (Settings ▸ Speech ▸ Speech source = Endpoint):"
        let plan = AVSpeechService.utterancePlan(text: text,
                                                 settings: settings("en.alex"),
                                                 voices: voices)
        #expect(plan == [UtterancePlan(text: "Источник «", voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: "Endpoint» (Settings ▸ Speech ▸ Speech source = Endpoint):",
                                       voiceID: "en.alex")])
    }
}
