import Foundation

/// Where a transcript's audio came from. `call` is reserved for call recording, which stores
/// into the same table; nothing produces it yet.
enum TranscriptSourceKind: String, Sendable, Equatable, CaseIterable {
    case file
    case call
}

enum TranscriptStatus: String, Sendable, Equatable, CaseIterable {
    case inProgress
    case complete
    case incomplete
}

/// One stretch of speech, timed from the start of the source.
struct TranscriptSegment: Sendable, Equatable {
    let start: TimeInterval
    let end: TimeInterval
    /// What the transcript shows: the recogniser output after glossary normalisation.
    let text: String
    /// The recogniser's own words, only when normalisation rewrote them — `nil` otherwise,
    /// as in dictation history.
    let rawText: String?

    init(start: TimeInterval, end: TimeInterval, text: String, rawText: String? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.rawText = rawText
    }
}

/// A transcript as the list shows it, without its segments.
struct TranscriptHeader: Identifiable, Sendable, Equatable {
    let id: Int64
    let createdAt: Date
    let sourceKind: TranscriptSourceKind
    let title: String
    /// Seconds. `nil` when the source reported no duration.
    let duration: TimeInterval?
    let status: TranscriptStatus
    /// Why an `incomplete` transcript stopped. Never contains transcript text or API keys.
    let statusReason: String?
}

struct Transcript: Sendable, Equatable {
    let header: TranscriptHeader
    let run: TranscriptionRun
    /// A bookmark to the source file, so `Resume` can reopen it after the file moved.
    let sourceBookmark: Data?
    let summary: String?
    let segments: [TranscriptSegment]

    var id: Int64 { header.id }

    /// Segment texts, one per line, without timestamps.
    var plainText: String {
        segments.map(\.text).joined(separator: "\n")
    }

    /// Where `Resume` restarts decoding: the end of the last stored segment.
    var resumePosition: TimeInterval {
        segments.last?.end ?? 0
    }
}
