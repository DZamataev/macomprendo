import Foundation

/// What normalisation did to one transcript: the corrected text, plus every rewrite it made.
///
/// A caller that ignores the rewrites still gets the plain string; the post-dictation review
/// window (its own spec) is what the rewrites exist for.
struct NormalisationResult: Equatable, Sendable {
    /// One recognised term rewritten to its canonical spelling.
    struct Rewrite: Equatable, Sendable {
        /// Where the canonical spelling sits in `text` — the **final** string, not the input.
        /// `Safe Area View` → `SafeAreaView` shortens the text as it goes, so a range computed
        /// against the input and returned unadjusted would underline the wrong words.
        let range: Range<String.Index>
        /// The substring that was replaced, exactly as the recogniser wrote it, without the
        /// punctuation that was detached around it.
        let original: String
        /// The spelling it was replaced with — the canonical spelling, possibly with its first
        /// letter capitalised because the window started a sentence.
        let term: String
        /// The pack that owns the term, or `nil` when it came from the manual list.
        let packName: String?
    }

    /// The corrected text. Identical to the input when nothing matched.
    let text: String
    /// Every rewrite, in the order they appear in `text`. Empty when nothing changed.
    let rewrites: [Rewrite]
}

/// Rewrites recognised terms to their canonical spelling. Pure text, running after
/// transcription under every backend.
///
/// Casing and splitting were 55 % of the control dictation's failures and are the same defect:
/// the model heard the term correctly and wrote it in the wrong shape. That is not a decoding
/// choice, so it has an exact answer — match on a key that ignores case and separators, and
/// paste the canonical spelling.
///
/// Deliberately absent: edit distance, phonetic matching, any threshold. Exact key equality
/// only. A fuzzy corrector's thresholds are the reason it can rewrite a correctly-heard word
/// into a wrong one; `jq` → `GQ` and `ruff` → `RAV` are failures this must leave alone.
enum Normalizer {
    /// The longest window the matcher considers, in words.
    private static let maximumWindowWords = 4

    /// Characters that end a sentence. A window never crosses one — because the key drops dots,
    /// `Закрыл Xcode. Build упал` would otherwise key `Xcode. Build` to `xcodebuild`. `:` and
    /// `;` stop a window too, but they do not *begin* a sentence, so they carry no capital.
    private static let clauseEnders: Set<Character> = [".", "!", "?", "…", ":", ";"]

    /// The subset of `clauseEnders` that begins a new sentence after it.
    private static let sentenceEnders: Set<Character> = [".", "!", "?", "…", "\n", "\r"]

    /// Brackets and quotation marks. These stop a window wherever they appear inside it,
    /// including inside a single word: `Xcode«build` is two words run together typographically,
    /// whereas `MainMenu.tscn` is one word that happens to contain a dot.
    ///
    /// Apostrophes (`'` and `’`) are deliberately **not** quotation marks here: they occur
    /// inside words, and treating them as boundaries would stop windows in ordinary text.
    private static let bracketsAndQuotes: Set<Character> = [
        "(", ")", "[", "]", "{", "}", "<", ">",
        "\"", "«", "»", "„", "“", "”", "‹", "›", "`",
    ]

    /// Rewrites every recognised term in `text` to its canonical spelling.
    ///
    /// A single forward pass. At each word position it tries a window of 4 words down to 1 and
    /// takes the first match, so the longest window wins and `Safe Area View` becomes
    /// `SafeAreaView` rather than leaving `View` behind.
    static func normalise(_ text: String, with glossary: Glossary) -> NormalisationResult {
        guard glossary.termCount > 0, !text.isEmpty else {
            return NormalisationResult(text: text, rewrites: [])
        }

        let words = wordRanges(in: text)
        guard !words.isEmpty else { return NormalisationResult(text: text, rewrites: []) }

        var output = ""
        output.reserveCapacity(text.count)
        // Offsets are counted in characters of `output` as it is built, because appending to a
        // String invalidates its indices; they become ranges once the final string exists.
        var pending: [(offset: Int, length: Int, original: String, term: String, packName: String?)] = []
        var cursor = text.startIndex
        var index = 0

        while index < words.count {
            var matched = false
            let longest = min(Self.maximumWindowWords, words.count - index)

            for length in stride(from: longest, through: 1, by: -1) {
                let span = words[index].lowerBound..<words[index + length - 1].upperBound
                guard let core = coreRange(of: span, in: text) else { continue }
                guard !isBlocked(text[core]) else { continue }

                let original = String(text[core])
                guard let entry = glossary.entry(forKey: Glossary.key(for: original)) else { continue }

                let startsSentence = beginsASentence(at: core.lowerBound, in: text)
                // A pack holding `swift` must not turn `Swift хорош` into `swift хорош`: when a
                // window starts a sentence, the replacement keeps the capital the window had,
                // so a first-letter-case-only difference resolves to the original text and is
                // not a rewrite at all. Any other difference is still corrected, and the capital
                // survives it: `Xcode build упал` becomes `Xcodebuild упал`.
                //
                // Only a capital the window already had is protected. A lowercase `swift`
                // opening a sentence against a pack holding `Swift` is still raised — there the
                // canonical spelling and the sentence's capital want the same letter.
                let replacement = startsSentence && (original.first?.isUppercase ?? false)
                    ? capitalisingFirstLetter(entry.canonical)
                    : entry.canonical

                output.append(contentsOf: text[cursor..<core.lowerBound])
                if replacement != original {
                    pending.append((
                        offset: output.count,
                        length: replacement.count,
                        original: original,
                        term: replacement,
                        packName: entry.packName
                    ))
                }
                output.append(replacement)
                cursor = core.upperBound
                index += length
                matched = true
                break
            }

            if !matched { index += 1 }
        }

        output.append(contentsOf: text[cursor...])

        let rewrites = pending.map { item in
            let start = output.index(output.startIndex, offsetBy: item.offset)
            let end = output.index(start, offsetBy: item.length)
            return NormalisationResult.Rewrite(
                range: start..<end,
                original: item.original,
                term: item.term,
                packName: item.packName
            )
        }
        return NormalisationResult(text: output, rewrites: rewrites)
    }

    // MARK: - Windows

    /// The ranges of the whitespace-separated words of `text`, in order.
    private static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                if let open = start { ranges.append(open..<index) }
                start = nil
            } else if start == nil {
                start = index
            }
            index = text.index(after: index)
        }
        if let open = start { ranges.append(open..<text.endIndex) }
        return ranges
    }

    /// A window's span without its leading and trailing punctuation, which is detached before
    /// keying and re-attached after — `xcodebuild,` normalises and keeps its comma. `nil` when
    /// nothing keyable is left.
    private static func coreRange(
        of span: Range<String.Index>,
        in text: String
    ) -> Range<String.Index>? {
        var lower = span.lowerBound
        while lower < span.upperBound, !isKeyable(text[lower]) {
            lower = text.index(after: lower)
        }
        guard lower < span.upperBound else { return nil }
        var upper = span.upperBound
        while upper > lower {
            let previous = text.index(before: upper)
            if isKeyable(text[previous]) { break }
            upper = previous
        }
        return lower..<upper
    }

    /// Whether a window's core crosses a boundary and must not be matched.
    ///
    /// A clause ender counts only when whitespace sits beside it, so `MainMenu.tscn` stays one
    /// matchable word while `Xcode. Build` and `Xcode .Build` do not. A newline always counts,
    /// and so does a bracket or quotation mark wherever it appears.
    private static func isBlocked(_ core: Substring) -> Bool {
        var previous: Character?
        var index = core.startIndex
        while index < core.endIndex {
            let character = core[index]
            let next = core.index(after: index)
            if character.isNewline || bracketsAndQuotes.contains(character) { return true }
            if clauseEnders.contains(character) {
                let following: Character? = next < core.endIndex ? core[next] : nil
                if previous?.isWhitespace ?? false { return true }
                if following?.isWhitespace ?? false { return true }
            }
            previous = character
            index = next
        }
        return false
    }

    private static func isKeyable(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - The sentence capital

    /// Whether the character at `position` opens a sentence: nothing but punctuation, brackets,
    /// quotes and whitespace lies between it and the previous sentence ender or the text start.
    ///
    /// Computed against the input rather than the text built so far, so a canonical spelling
    /// that happens to contain a dot (`MainMenu.tscn`) cannot invent a sentence boundary for the
    /// words after it.
    private static func beginsASentence(at position: String.Index, in text: String) -> Bool {
        var index = position
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if sentenceEnders.contains(character) || character.isNewline { return true }
            if isKeyable(character) { return false }
        }
        return true
    }

    /// `text` with its first letter raised, used to keep a sentence's capital on a rewrite.
    private static func capitalisingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}
