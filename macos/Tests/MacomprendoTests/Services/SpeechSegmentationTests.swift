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

    private func settings(_ voiceID: String?,
                          map: [String: String] = [:],
                          segmentation: Bool = true) -> SpeechSettings {
        var s = SpeechSettings(voiceID: voiceID, rate: 0.5, pitch: 1, volume: 1)
        s.voiceByLanguage = map
        s.segmentationEnabled = segmentation
        return s
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
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: latinPart, voiceID: "en.alex")])
    }

    @Test func mixedScriptTextSwitchesVoicePerRun() {
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: latinPart, voiceID: "en.alex")])
    }

    @Test func aMissingFallbackVoiceKeepsTheConfiguredVoice() {
        // Every run resolves to the configured voice (no Cyrillic voice is installed to
        // switch to), so the plan collapses back to a single utterance holding the original
        // text — byte for byte what the service did before segmentation existed.
        let englishOnly = voices.filter { $0.language.hasPrefix("en") }
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings("en.alex"),
                                                 voices: englishOnly,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: cyrillicPart + latinPart, voiceID: "en.alex")])
    }

    @Test func textIsSplitEvenWhenNoVoiceIsConfigured() {
        // No configured voice means the configured script is assumed Latin.
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart + latinPart,
                                                 settings: settings(nil),
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: latinPart, voiceID: nil)])
    }

    @Test func aSingleRunInTheWrongScriptStillSwitchesVoice() {
        // Wholly-Cyrillic text with no Latin run at all: the spec's algorithm has no
        // single-run exemption, so this must still switch to the Cyrillic fallback voice
        // instead of mangling the text under the configured English voice.
        let plan = AVSpeechService.utterancePlan(text: cyrillicPart,
                                                 settings: settings("en.alex"),
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: cyrillicPart, voiceID: "ru.milena.enhanced")])
    }

    @Test func aSingleForeignWordDoesNotSplitTheUtterance() {
        // "Zoom" is 4 letters, under the default minimum of 6, so it merges into the
        // Cyrillic run and the whole sentence stays one utterance.
        let text = "Я купил новый Zoom вчера в магазине рядом с домом."
        let plan = AVSpeechService.utterancePlan(text: text,
                                                 settings: settings("ru.milena"),
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: text, voiceID: "ru.milena")])
    }

    @Test func neutralOnlyTextStaysOneUtterance() {
        let plan = AVSpeechService.utterancePlan(text: "123 456 …",
                                                 settings: settings("en.alex"),
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
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
                                                 voices: voices,
                                                 detector: ScriptedLanguageDetector())
        #expect(plan == [UtterancePlan(text: "Источник «", voiceID: "ru.milena.enhanced"),
                         UtterancePlan(text: "Endpoint» (Settings ▸ Speech ▸ Speech source = Endpoint):",
                                       voiceID: "en.alex")])
    }

    // MARK: language-mapped voices

    @Test func segmentationOffProducesExactlyOneUtteranceWithTheDefaultVoice() {
        let text = cyrillicPart + latinPart
        let plan = AVSpeechService.utterancePlan(
            text: text,
            settings: settings("en.alex", segmentation: false),
            voices: voices,
            detector: ScriptedLanguageDetector(["anything": "ru"]))
        #expect(plan == [UtterancePlan(text: text, voiceID: "en.alex")])
    }

    @Test func aMappedLanguageWinsOverTheAutomaticFallback() {
        let runs = LanguageSegmenter.runs(in: cyrillicPart + latinPart)
        let detector = ScriptedLanguageDetector(Dictionary(uniqueKeysWithValues: runs.map {
            ($0.text, $0.script == .cyrillic ? "ru" : "en")
        }))
        let plan = AVSpeechService.utterancePlan(
            text: cyrillicPart + latinPart,
            settings: settings("en.alex", map: ["ru": "ru.milena"]),
            voices: voices,
            detector: detector)
        // Without the map the Cyrillic run would take the enhanced Milena via fallbackVoice.
        #expect(plan.first(where: { $0.text.contains("русское") })?.voiceID == "ru.milena")
    }

    @Test func anUnmappedLanguageStillUsesTheAutomaticFallback() {
        let runs = LanguageSegmenter.runs(in: cyrillicPart + latinPart)
        let detector = ScriptedLanguageDetector(Dictionary(uniqueKeysWithValues: runs.map {
            ($0.text, $0.script == .cyrillic ? "ru" : "en")
        }))
        let plan = AVSpeechService.utterancePlan(
            text: cyrillicPart + latinPart,
            settings: settings("en.alex"),
            voices: voices,
            detector: detector)
        #expect(plan.first(where: { $0.text.contains("русское") })?.voiceID == "ru.milena.enhanced")
    }

    @Test func aMappedVoiceThatIsNotInstalledIsIgnored() {
        let runs = LanguageSegmenter.runs(in: cyrillicPart + latinPart)
        let detector = ScriptedLanguageDetector(Dictionary(uniqueKeysWithValues: runs.map {
            ($0.text, $0.script == .cyrillic ? "ru" : "en")
        }))
        let plan = AVSpeechService.utterancePlan(
            text: cyrillicPart + latinPart,
            settings: settings("en.alex", map: ["ru": "ru.uninstalled"]),
            voices: voices,
            detector: detector)
        #expect(plan.first(where: { $0.text.contains("русское") })?.voiceID == "ru.milena.enhanced")
    }

    /// "Привет." is a 6-letter Cyrillic run, and Cyrillic runs never merge into a Latin
    /// neighbour — so it survives as its own run and is below the threshold, while the long
    /// Latin run is above it. Asserting both halves is what makes this test fail against a
    /// broken threshold instead of passing vacuously on an empty question list.
    @Test func onlyRunsLongEnoughToBeTrustworthyAreSentToTheDetector() {
        let detector = ScriptedLanguageDetector()
        _ = AVSpeechService.utterancePlan(
            text: "Привет. This is a reasonably long English sentence here.",
            settings: settings("en.alex", map: ["ru": "ru.milena"]),
            voices: voices,
            detector: detector)
        #expect(detector.asked.count == 1)
        #expect(detector.asked.first?.contains("reasonably") == true)
        #expect(detector.asked.allSatisfy {
            LanguageSegmenter.letterCount($0) >= AVSpeechService.minDetectionLetters
        })
    }

    @Test func aPlanThatResolvesToOneVoiceCollapsesToTheOriginalText() {
        let text = "Now a long English sentence follows here and continues."
        let plan = AVSpeechService.utterancePlan(
            text: text,
            settings: settings("en.alex"),
            voices: voices,
            detector: ScriptedLanguageDetector([text: "en"]))
        #expect(plan == [UtterancePlan(text: text, voiceID: "en.alex")])
    }

    /// Two languages mapped to the same voice used to survive as N utterances: the collapse
    /// only compared each run against `settings.voiceID`. `AVSpeechSynthesizer` puts an audible
    /// boundary between queued utterances, so the user heard a seam per run for no reason.
    @Test func twoLanguagesMappedToOneVoiceCollapseToASingleUtterance() {
        let text = cyrillicPart + latinPart
        let plan = AVSpeechService.utterancePlan(
            text: text,
            settings: settings("en.alex", map: ["ru": "ru.milena", "en": "ru.milena"]),
            voices: voices,
            detector: ScriptedLanguageDetector([cyrillicPart: "ru", latinPart: "en"]))
        #expect(plan == [UtterancePlan(text: text, voiceID: "ru.milena")])
    }

    /// The default configuration maps nothing, and detection is only ever used to look up that
    /// map — so asking `NLLanguageRecognizer` per run on the main actor would be pure cost.
    @Test func detectionIsSkippedEntirelyWhenNoLanguageIsMapped() {
        let detector = ScriptedLanguageDetector()
        let text = cyrillicPart + latinPart
        let plan = AVSpeechService.utterancePlan(text: text,
                                                 settings: settings("en.alex"),
                                                 voices: voices,
                                                 detector: detector)
        #expect(detector.asked.isEmpty)
        // The script-based fallback still runs, so the plan is unchanged by the shortcut.
        #expect(plan.map(\.voiceID) == ["ru.milena.enhanced", "en.alex"])
    }

    @Test func emptyTextProducesNoUtterances() {
        #expect(AVSpeechService.utterancePlan(text: "", settings: settings("en.alex"),
                                              voices: voices,
                                              detector: ScriptedLanguageDetector()).isEmpty)
    }
}
