import Foundation

/// Splits a transcript into parts an LLM can summarise one at a time. Pure.
enum TranscriptChunker {
    static let defaultLimit = 12_000

    /// Whole segments joined by newlines, each part at most `limit` characters — except a
    /// single segment longer than `limit`, which becomes a part of its own rather than being
    /// cut mid-sentence. Empty input gives no parts.
    static func parts(of segments: [TranscriptSegment], limit: Int = defaultLimit) -> [String] {
        var parts: [String] = []
        var current = ""
        for segment in segments {
            let text = segment.text
            if current.isEmpty {
                current = text
            } else if current.count + 1 + text.count <= limit {
                current += "\n" + text
            } else {
                parts.append(current)
                current = text
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
