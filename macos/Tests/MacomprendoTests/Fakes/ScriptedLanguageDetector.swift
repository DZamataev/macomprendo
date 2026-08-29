import Foundation
@testable import Macomprendo

/// Answers from a table keyed by the exact text it is asked about, so a segmentation test
/// controls the detected language of every run without depending on NaturalLanguage.
final class ScriptedLanguageDetector: LanguageDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: String]
    private var questions: [String] = []

    /// Text that is not in the table is reported as undetectable.
    init(_ answers: [String: String] = [:]) {
        self.answers = answers
    }

    /// Every text the planner asked about, in order.
    var asked: [String] { lock.withLock { questions } }

    func dominantLanguage(of text: String) -> String? {
        lock.withLock {
            questions.append(text)
            return answers[text]
        }
    }
}
