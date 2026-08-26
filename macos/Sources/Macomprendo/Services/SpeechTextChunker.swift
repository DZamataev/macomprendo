import Foundation

/// Splits text into request-sized pieces for an OpenAI-compatible `/v1/audio/speech` endpoint.
/// Pure: no state, no I/O.
///
/// Sentences are the preferred boundary, so a chunk seam lands where a speaker would pause.
/// Sentences are regrouped greedily up to the limit, which means an abbreviation that looks
/// like a sentence end ("Dr.") only affects *where* a seam could fall, never the text.
///
/// The limit is counted in **characters**: OpenAI documents a 4096-character input cap for
/// this endpoint, so Cyrillic costs the same as Latin here.
enum SpeechTextChunker {
    /// The documented `/v1/audio/speech` input cap.
    static let defaultCharacterLimit = 4096

    static let sentenceTerminators: Set<Character> = [".", "!", "?", "…", "\u{3002}", "\u{FF01}", "\u{FF1F}"]
    static let closingCharacters: Set<Character> = ["\"", "'", ")", "]", "\u{00BB}", "\u{201D}", "\u{2019}"]

    static func chunks(of text: String, limit: Int = defaultCharacterLimit) -> [String] {
        guard limit > 0 else { return [] }
        var chunks: [String] = []
        var current = ""

        for sentence in sentences(in: text) {
            for piece in splitOversized(sentence, limit: limit) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 1 + piece.count <= limit {
                    current += " " + piece
                } else {
                    chunks.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Sentences, trimmed, keeping any closing quote or bracket that follows the terminator.
    /// A terminator only ends a sentence when whitespace or the end of the text follows it,
    /// and every newline ends one too.
    static func sentences(in text: String) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0

        func emit(upTo end: Int) {
            let piece = String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { sentences.append(piece) }
            start = end
        }

        while index < characters.count {
            let character = characters[index]
            if sentenceTerminators.contains(character) {
                var end = index + 1
                while end < characters.count, closingCharacters.contains(characters[end]) { end += 1 }
                if end >= characters.count || characters[end].isWhitespace {
                    emit(upTo: end)
                    index = end
                    continue
                }
            }
            if character.isNewline { emit(upTo: index + 1) }
            index += 1
        }
        emit(upTo: characters.count)
        return sentences
    }

    /// A sentence over the limit is regrouped at word boundaries.
    static func splitOversized(_ sentence: String, limit: Int) -> [String] {
        guard sentence.count > limit else { return [sentence] }
        var pieces: [String] = []
        var current = ""
        for word in sentence.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            for fragment in splitWord(word, limit: limit) {
                if current.isEmpty {
                    current = fragment
                } else if current.count + 1 + fragment.count <= limit {
                    current += " " + fragment
                } else {
                    pieces.append(current)
                    current = fragment
                }
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// A single word over the limit is cut at grapheme boundaries, so every fragment stays
    /// valid text.
    static func splitWord(_ word: String, limit: Int) -> [String] {
        guard word.count > limit else { return [word] }
        var pieces: [String] = []
        var current = ""
        for character in word {
            if current.count == limit {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
