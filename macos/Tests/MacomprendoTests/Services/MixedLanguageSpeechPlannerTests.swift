import Testing
@testable import Macomprendo

@Suite struct MixedLanguageSpeechPlannerTests {
    @Test func disabledPlanningPreservesTheOriginalTextAndDefaultSelection() {
        let text = "Привет. Hello."

        let plan = MixedLanguageSpeechPlanner.plan(
            text: text,
            enabled: false,
            defaultSelection: "default",
            detectLanguages: true,
            detector: ScriptedLanguageDetector([text: "ru"]),
            resolve: { _, _ in "mapped" })

        #expect(plan == [PlannedSpeechRun(text: text, selection: "default")])
    }

    @Test func enabledPlanningResolvesEachLanguageRun() {
        let russian = "Это длинное русское предложение. "
        let english = "This is a long English sentence."
        let detector = ScriptedLanguageDetector([russian: "ru", english: "en"])

        let plan = MixedLanguageSpeechPlanner.plan(
            text: russian + english,
            enabled: true,
            defaultSelection: "default",
            detectLanguages: true,
            detector: detector,
            resolve: { _, language in language ?? "auto" })

        #expect(plan == [
            PlannedSpeechRun(text: russian, selection: "ru"),
            PlannedSpeechRun(text: english, selection: "en"),
        ])
        #expect(detector.asked == [russian, english])
    }

    @Test func onlyTrustworthyRunsAreSentToTheDetector() {
        let shortRussian = "Привет. "
        let english = "This is a reasonably long English sentence."
        let detector = ScriptedLanguageDetector([english: "en"])

        let plan = MixedLanguageSpeechPlanner.plan(
            text: shortRussian + english,
            enabled: true,
            defaultSelection: "default",
            detectLanguages: true,
            detector: detector,
            resolve: { run, language in
                language ?? (run.script == .cyrillic ? "cyrillic" : "latin")
            })

        #expect(detector.asked == [english])
        #expect(plan.map(\.selection) == ["cyrillic", "en"])
    }

    @Test func detectionCanBeSkippedWithoutChangingSegmentation() {
        let detector = ScriptedLanguageDetector()

        let plan = MixedLanguageSpeechPlanner.plan(
            text: "Длинное русское предложение. A long English sentence.",
            enabled: true,
            defaultSelection: "default",
            detectLanguages: false,
            detector: detector,
            resolve: { run, language in
                #expect(language == nil)
                return run.script == .cyrillic ? "ru" : "en"
            })

        #expect(detector.asked.isEmpty)
        #expect(plan.map(\.selection) == ["ru", "en"])
    }

    @Test func adjacentEqualSelectionsAreCoalesced() {
        let first = "Длинное русское предложение. "
        let middle = "A long English sentence. "
        let last = "Второе длинное русское предложение."

        let plan = MixedLanguageSpeechPlanner.plan(
            text: first + middle + last,
            enabled: true,
            defaultSelection: "default",
            detectLanguages: false,
            detector: ScriptedLanguageDetector(),
            resolve: { run, _ in run.text == last ? "second" : "first" })

        #expect(plan == [
            PlannedSpeechRun(text: first + middle, selection: "first"),
            PlannedSpeechRun(text: last, selection: "second"),
        ])
    }

    @Test func oneResolvedSelectionRestoresTheOriginalText() {
        let text = "Длинное русское предложение. A long English sentence."

        let plan = MixedLanguageSpeechPlanner.plan(
            text: text,
            enabled: true,
            defaultSelection: "default",
            detectLanguages: false,
            detector: ScriptedLanguageDetector(),
            resolve: { _, _ in "same" })

        #expect(plan == [PlannedSpeechRun(text: text, selection: "same")])
    }
}
