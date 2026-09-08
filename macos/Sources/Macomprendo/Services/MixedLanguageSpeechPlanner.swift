import Foundation

struct PlannedSpeechRun<Selection: Hashable & Sendable>: Sendable, Equatable {
    let text: String
    let selection: Selection
}

enum MixedLanguageSpeechPlanner {
    static let minDetectionLetters = 12

    nonisolated static func plan<Selection: Hashable & Sendable>(
        text: String,
        enabled: Bool,
        defaultSelection: Selection,
        detectLanguages: Bool,
        detector: any LanguageDetecting,
        minRunLength: Int = LanguageSegmenter.defaultMinRunLength,
        resolve: (TextRun, String?) -> Selection
    ) -> [PlannedSpeechRun<Selection>] {
        guard !text.isEmpty else { return [] }
        guard enabled else {
            return [PlannedSpeechRun(text: text, selection: defaultSelection)]
        }
        let resolved = LanguageSegmenter.runs(in: text, minRunLength: minRunLength).map { run in
            let language = detectLanguages && LanguageSegmenter.letterCount(run.text) >= minDetectionLetters
                ? detector.dominantLanguage(of: run.text)
                : nil
            return PlannedSpeechRun(text: run.text, selection: resolve(run, language))
        }
        return resolved.reduce(into: []) { coalesced, run in
            if coalesced.last?.selection == run.selection {
                let previous = coalesced.removeLast()
                coalesced.append(PlannedSpeechRun(
                    text: previous.text + run.text,
                    selection: run.selection))
            } else {
                coalesced.append(run)
            }
        }
    }
}
