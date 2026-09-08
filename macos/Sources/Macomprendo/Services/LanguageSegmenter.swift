import Foundation

enum ScriptClass: Equatable, Sendable { case cyrillic, latin, han, neutral }

struct TextRun: Equatable, Sendable {
    var text: String
    var script: ScriptClass
}

/// Splits text into maximal runs of one script so a mixed Cyrillic/Latin selection can be
/// read by two different voices. Pure: no state, no I/O.
///
/// Merging is ASYMMETRIC, because the failure modes are asymmetric: a Russian voice reads
/// Latin text with an accent but intelligibly, while an English voice reading Cyrillic
/// collapses into character spelling ("Cyrillic letter E…"). Therefore:
/// - A LATIN run with fewer than `minRunLength` LETTERS merges into a neighboring Cyrillic
///   run ("Merge" inside a Russian sentence stays with the Russian voice — accented but
///   intelligible).
/// - A CYRILLIC run NEVER merges into a Latin neighbor, no matter how short: even a single
///   Russian word gets its own Cyrillic run (a brief voice switch beats letter-spelling).
/// - Run length for merge decisions counts ONLY letters — attached neutral characters
///   (digits, punctuation, whitespace) never influence the comparison, so
///   "(swift 538/538, node 38/38)" is a 17-letter Latin run, not a 39-character one.
///
/// - Note: The Swift standard library exposes no `Unicode.Scalar.Properties.script`, so
///   classification uses explicit block ranges. Han can be separated by Local speech without
///   changing the shipped System segmentation; other scripts, digits, punctuation, whitespace,
///   and emoji remain `.neutral` and attach to a neighbouring run.
enum LanguageSegmenter {
    /// A Latin run with fewer than this many LETTERS merges into a neighboring Cyrillic run,
    /// so a single short foreign word ("Merge" inside a Russian sentence) does not flip the
    /// voice for one word. Cyrillic runs never merge, regardless of `minRunLength`.
    static let defaultMinRunLength = 6

    /// Base language codes written in Cyrillic.
    static let cyrillicLanguageCodes: Set<String> = [
        "ab", "ba", "be", "bg", "ce", "cv", "kk", "ky", "mk", "mn",
        "os", "ru", "sr", "tg", "tt", "uk"
    ]

    /// Base language codes written in neither Cyrillic nor Latin. Voices for these languages
    /// are never picked as a fallback for a Latin run.
    static let nonLatinLanguageCodes: Set<String> = [
        "am", "ar", "bn", "el", "fa", "gu", "he", "hi", "hy", "iw", "ja", "ka", "km", "kn",
        "ko", "lo", "ml", "mr", "my", "ne", "pa", "si", "ta", "te", "th", "ur", "yi", "zh"
    ]

    private static let cyrillicRanges: [ClosedRange<UInt32>] = [
        0x0400...0x04FF,   // Cyrillic
        0x0500...0x052F,   // Cyrillic Supplement
        0x1C80...0x1C8F,   // Cyrillic Extended-C
        0x2DE0...0x2DFF,   // Cyrillic Extended-A
        0xA640...0xA69F    // Cyrillic Extended-B
    ]

    private static let latinRanges: [ClosedRange<UInt32>] = [
        0x0041...0x005A,   // A–Z
        0x0061...0x007A,   // a–z
        0x00C0...0x024F,   // Latin-1 Supplement letters, Latin Extended-A/B
        0x1E00...0x1EFF,   // Latin Extended Additional
        0x2C60...0x2C7F    // Latin Extended-C
    ]

    private static let hanRanges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,   // CJK Unified Ideographs Extension A
        0x4E00...0x9FFF,   // CJK Unified Ideographs
        0xF900...0xFAFF,   // CJK Compatibility Ideographs
        0x20000...0x3134F  // CJK Unified Ideographs Extensions B–H
    ]

    static func script(of scalar: Unicode.Scalar, separateHan: Bool = false) -> ScriptClass {
        guard scalar.properties.isAlphabetic else { return .neutral }
        let value = scalar.value
        if cyrillicRanges.contains(where: { $0.contains(value) }) { return .cyrillic }
        if latinRanges.contains(where: { $0.contains(value) }) { return .latin }
        if separateHan, hanRanges.contains(where: { $0.contains(value) }) { return .han }
        return .neutral
    }

    /// A grapheme counts as Cyrillic/Latin when any of its scalars does, so a base letter
    /// plus combining marks ("й" spelled и + U+0306) stays with its letter.
    static func script(of character: Character, separateHan: Bool = false) -> ScriptClass {
        for scalar in character.unicodeScalars {
            let scriptClass = script(of: scalar, separateHan: separateHan)
            if scriptClass != .neutral { return scriptClass }
        }
        return .neutral
    }

    /// The script a BCP-47 tag is written in, by base code. Unknown codes are assumed Latin.
    static func script(ofLanguage language: String, separateHan: Bool = false) -> ScriptClass {
        let base = language.split(separator: "-").first.map { $0.lowercased() } ?? ""
        if cyrillicLanguageCodes.contains(base) { return .cyrillic }
        if separateHan, base == "zh" { return .han }
        if nonLatinLanguageCodes.contains(base) { return .neutral }
        return .latin
    }

    /// Maximal runs of one script. Neutral characters attach to the preceding run, or to the
    /// following one at the start of the text. A Latin run with fewer than `minRunLength`
    /// LETTERS merges into a neighboring Cyrillic run; Cyrillic runs never merge (see the
    /// type doc comment for why the rule is asymmetric).
    static func runs(
        in text: String,
        minRunLength: Int = defaultMinRunLength,
        separateHan: Bool = false
    ) -> [TextRun] {
        guard !text.isEmpty else { return [] }

        var runs: [TextRun] = []
        for character in text {
            let scriptClass = script(of: character, separateHan: separateHan)
            guard var last = runs.last else {
                runs.append(TextRun(text: String(character), script: scriptClass))
                continue
            }
            if scriptClass == .neutral || last.script == scriptClass {
                last.text.append(character)                  // neutral joins the current run
                runs[runs.count - 1] = last
            } else if last.script == .neutral {
                last.text.append(character)                  // leading neutrals adopt this script
                last.script = scriptClass
                runs[runs.count - 1] = last
            } else {
                runs.append(TextRun(text: String(character), script: scriptClass))
            }
        }

        // Short Latin fragments merge only into Cyrillic. Local-only Han runs remain independent.
        // Each iteration removes one run, so this terminates at a single run at the latest.
        while runs.count > 1, let index = shortLatinIndex(below: minRunLength, in: runs) {
            let left = index - 1
            let right = index + 1
            let mergeLeft = left >= 0 && runs[left].script == .cyrillic
            let neighbor = mergeLeft ? left : right
            let first = mergeLeft ? neighbor : index
            let second = mergeLeft ? index : neighbor
            runs[first] = combine(runs[first], runs[second])
            runs.remove(at: second)
        }

        var coalesced: [TextRun] = []
        for run in runs {
            if coalesced.last?.script == run.script {
                coalesced[coalesced.count - 1].text += run.text
            } else {
                coalesced.append(run)
            }
        }
        return coalesced
    }

    /// The first short Latin run adjacent to Cyrillic. Other scripts never absorb it.
    private static func shortLatinIndex(below minRunLength: Int, in runs: [TextRun]) -> Int? {
        for index in runs.indices
        where runs[index].script == .latin
            && letterCount(runs[index]) < minRunLength
            && ((index > runs.startIndex && runs[index - 1].script == .cyrillic)
                || (index < runs.index(before: runs.endIndex)
                    && runs[index + 1].script == .cyrillic)) {
            return index
        }
        return nil
    }

    /// Counts letters separated by the selected planner mode, ignoring neutral characters.
    /// Internal because the speech planner uses it to decide whether a run is long enough for
    /// language detection to be trustworthy.
    static func letterCount(_ text: String, separateHan: Bool = false) -> Int {
        text.reduce(into: 0) { count, character in
            if script(of: character, separateHan: separateHan) != .neutral { count += 1 }
        }
    }

    private static func letterCount(_ run: TextRun) -> Int { letterCount(run.text) }

    /// Cyrillic always wins: this is only ever called to merge a short Latin run into an
    /// adjacent Cyrillic one, so the combined run must stay Cyrillic.
    private static func combine(_ first: TextRun, _ second: TextRun) -> TextRun {
        let winningScript: ScriptClass = (first.script == .cyrillic || second.script == .cyrillic)
            ? .cyrillic : first.script
        return TextRun(text: first.text + second.text, script: winningScript)
    }
}
