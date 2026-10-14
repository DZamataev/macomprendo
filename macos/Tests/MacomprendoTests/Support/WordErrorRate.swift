import Foundation

/// Word and character error rates for one hypothesis transcript against one reference —
/// Levenshtein distance over normalised tokens. The benchmark gym uses it to compare models;
/// it is test-support, so it lives with the tests rather than in the app.
///
/// Normalisation, both sides alike: lowercase, `ё`→`е`, punctuation removed, whitespace
/// collapsed, digits kept. A hyphen (any of `-`, `–`, `—`) separates words — recognisers do not
/// agree on `какой-то` vs `какой то`, and treating the two as equal keeps that disagreement out
/// of the score. Every other punctuation mark is dropped without splitting the word it sits in,
/// so `don't` normalises to `dont` rather than to two tokens.
enum WordErrorRate {

    /// The comparable words of `text`: letters and digits kept, everything else normalised away.
    static func words(_ text: String) -> [String] {
        let collapsed = normalisedText(text)
        return collapsed.isEmpty ? [] : collapsed.split(separator: " ").map(String.init)
    }

    /// The comparable characters of `text`: the normalised words joined, spaces removed.
    static func characters(_ text: String) -> [Character] {
        Array(normalisedText(text).filter { $0 != " " })
    }

    /// Standard Levenshtein distance — the fewest insertions, deletions and substitutions that
    /// turn `reference` into `hypothesis`. Two rolling rows, so memory is O(min(n, m)).
    static func levenshtein<T: Equatable>(of reference: [T], with hypothesis: [T]) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }

        var previous = Array(0...hypothesis.count)
        var current = [Int](repeating: 0, count: hypothesis.count + 1)
        // Iterating the longer side in the outer loop and the shorter in the inner keeps the
        // rolling rows as small as possible.
        for (index, referenceToken) in reference.enumerated() {
            current[0] = index + 1
            for (position, hypothesisToken) in hypothesis.enumerated() {
                let substitution = previous[position] + (referenceToken == hypothesisToken ? 0 : 1)
                current[position + 1] = min(previous[position + 1] + 1,   // a word deleted
                                            current[position] + 1,        // a word inserted
                                            substitution)
            }
            swap(&previous, &current)
        }
        return previous[hypothesis.count]
    }

    /// Word error rate as a fraction: `distance / reference word count`. `1.0` is 100 %.
    /// An empty reference is `0` against an empty hypothesis, and `1` against any speech —
    /// nothing was expected and something was said.
    static func wer(reference: String, hypothesis: String) -> Double {
        rate(words(reference), words(hypothesis))
    }

    /// Character error rate, same convention as `wer`.
    static func cer(reference: String, hypothesis: String) -> Double {
        rate(characters(reference), characters(hypothesis))
    }

    private static func rate<T: Equatable>(_ reference: [T], _ hypothesis: [T]) -> Double {
        if reference.isEmpty { return hypothesis.isEmpty ? 0 : 1 }
        return Double(levenshtein(of: reference, with: hypothesis)) / Double(reference.count)
    }

    /// Lowercase, `ё`→`е`, hyphen as a word boundary, other punctuation dropped, whitespace
    /// collapsed. Internal so the tests can pin each rule on its own (`character`-level rules
    /// are exercised through `words` and `characters`).
    static func normalisedText(_ text: String) -> String {
        var tokens: [String] = []
        var current = ""
        for character in text.lowercased() {
            let mapped = character == "ё" ? "е" : character
            if mapped.isLetter || mapped.isNumber {
                current.append(mapped)
            } else if mapped.isWhitespace || mapped == "-" || mapped == "–" || mapped == "—" {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            }
            // Anything else is punctuation: dropped without ending the word.
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens.joined(separator: " ")
    }
}

/// The text of a SubRip (.srt) reference file — cue text lines in order, nothing else. Cue
/// numbers, timestamp lines (`-->`) and the blank lines between cues are skipped. Deliberately
/// independent of the app's exporter: this reads files the app never wrote (YouTube's).
enum SubRipText {
    static func text(from contents: String) -> String {
        contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty
                    && line != "WEBVTT"
                    && !line.contains("-->")
                    && !line.allSatisfy(\.isNumber)
            }
            .joined(separator: "\n")
    }
}
