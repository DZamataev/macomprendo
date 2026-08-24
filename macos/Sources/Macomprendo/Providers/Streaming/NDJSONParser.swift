import Foundation

/// Splits a newline-delimited JSON stream (Ollama `/api/chat`, `/api/pull`) into
/// one `Data` per JSON document. Validation is the caller's job: providers know the
/// expected shape and raise `MacomprendoError.providerStreamMalformed` themselves.
struct NDJSONParser {
    private var splitter = LineSplitter()

    mutating func feed(_ data: Data) -> [Data] {
        splitter.feed(data).compactMap(Self.document)
    }

    /// Call once the stream ends, to pick up a final line with no trailing newline.
    mutating func finish() -> [Data] {
        guard let tail = splitter.flush(), let document = Self.document(tail) else { return [] }
        return [document]
    }

    private static func document(_ line: String) -> Data? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : Data(trimmed.utf8)
    }
}
