import Foundation

enum ScriptClass: Equatable, Sendable { case cyrillic, latin, neutral }

struct TextRun: Equatable, Sendable {
    var text: String
    var script: ScriptClass
}

/// Splits text into maximal runs of one script so a mixed Cyrillic/Latin selection can be
/// read by two different voices. Pure: no state, no I/O.
///
/// - Note: The Swift standard library exposes no `Unicode.Scalar.Properties.script`, so
///   classification is `isAlphabetic` plus explicit Unicode block ranges. Anything that is
///   not a Cyrillic or Latin letter — digits, punctuation, whitespace, Han, Arabic, emoji —
///   is `.neutral`, attaches to a neighbouring run and is therefore read by that run's voice.
///   Scripts outside Cyrillic/Latin never crash and never flip the voice on their own.
enum LanguageSegmenter {
    /// A non-neutral run shorter than this merges into a neighbour, so a single foreign word
    /// ("iPhone" inside a Russian sentence) does not flip the voice for one word.
    static let defaultMinRunLength = 20

    /// Base language codes written in Cyrillic.
    static let cyrillicLanguageCodes: Set<String> = [
        "ab", "ba", "be", "bg", "ce", "cv", "kk", "ky", "mk", "mn",
        "os", "ru", "sr", "tg", "tt", "uk"
    ]

    /// Base language codes written in neither Cyrillic nor Latin. Voices for these languages
    /// are never picked as a fallback for a Latin run.
    static let otherScriptLanguageCodes: Set<String> = [
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

    static func script(of scalar: Unicode.Scalar) -> ScriptClass {
        guard scalar.properties.isAlphabetic else { return .neutral }
        let value = scalar.value
        if cyrillicRanges.contains(where: { $0.contains(value) }) { return .cyrillic }
        if latinRanges.contains(where: { $0.contains(value) }) { return .latin }
        return .neutral
    }

    /// A grapheme counts as Cyrillic/Latin when any of its scalars does, so a base letter
    /// plus combining marks ("й" spelled и + U+0306) stays with its letter.
    static func script(of character: Character) -> ScriptClass {
        for scalar in character.unicodeScalars {
            let scriptClass = script(of: scalar)
            if scriptClass != .neutral { return scriptClass }
        }
        return .neutral
    }

    /// The script a BCP-47 tag is written in, by base code. Unknown codes are assumed Latin.
    static func script(ofLanguage language: String) -> ScriptClass {
        let base = language.split(separator: "-").first.map { $0.lowercased() } ?? ""
        if cyrillicLanguageCodes.contains(base) { return .cyrillic }
        if otherScriptLanguageCodes.contains(base) { return .neutral }
        return .latin
    }

    /// Maximal runs of one script. Neutral characters attach to the preceding run, or to the
    /// following one at the start of the text. A run shorter than `minRunLength` merges into
    /// its longer neighbour and the longer side's script wins.
    static func runs(in text: String, minRunLength: Int = defaultMinRunLength) -> [TextRun] {
        guard !text.isEmpty else { return [] }

        var runs: [TextRun] = []
        for character in text {
            let scriptClass = script(of: character)
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

        // Each iteration removes one run, so this terminates at a single run at the latest.
        while runs.count > 1, let short = shortestIndex(below: minRunLength, in: runs) {
            let left = short - 1
            let right = short + 1
            let mergeLeft: Bool
            if left < 0 {
                mergeLeft = false
            } else if right >= runs.count {
                mergeLeft = true
            } else {
                mergeLeft = runs[left].text.count >= runs[right].text.count
            }
            let first = mergeLeft ? left : short
            let second = mergeLeft ? short : right
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

    private static func shortestIndex(below minRunLength: Int, in runs: [TextRun]) -> Int? {
        var best: Int?
        for index in runs.indices where runs[index].text.count < minRunLength {
            if let current = best, runs[index].text.count >= runs[current].text.count { continue }
            best = index
        }
        return best
    }

    private static func combine(_ first: TextRun, _ second: TextRun) -> TextRun {
        TextRun(text: first.text + second.text,
                script: first.text.count >= second.text.count ? first.script : second.script)
    }
}
