import Foundation

/// Where a transcript's audio came from. Call recording produces `call` rows in the same table
/// as file transcripts; everything else is `file`.
enum TranscriptSourceKind: String, Sendable, Equatable, CaseIterable {
    case file
    case call
}

enum TranscriptStatus: String, Sendable, Equatable, CaseIterable {
    case inProgress
    case complete
    case incomplete
}

/// Which side of a recorded call a segment came from. Call recording stores the two sides as
/// separate tracks, so a segment carries its own; dictation and file transcription leave it nil.
enum TranscriptSpeaker: String, Sendable, Equatable, CaseIterable, Codable {
    case me
    case others

    var label: String {
        switch self {
        case .me: "Me"
        case .others: "Others"
        }
    }
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
    /// The call recording side this came from, or `nil` for every non-call transcript.
    let speaker: TranscriptSpeaker?

    init(start: TimeInterval, end: TimeInterval, text: String, rawText: String? = nil,
         speaker: TranscriptSpeaker? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.rawText = rawText
        self.speaker = speaker
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
    /// The stored LLM summary. Dormant: nothing writes it since `Summarize` opens the Quick
    /// Panel, where the summary is shown and not kept; the column, `setSummary` and the
    /// Markdown export's Summary section stay for call recording.
    let summary: String?
    let segments: [TranscriptSegment]

    var id: Int64 { header.id }

    /// Segment texts, one per line, without timestamps. A call recording's two sides are
    /// prefixed with their speaker so the interleaved lines still read as a conversation.
    var plainText: String {
        segments.map { s in s.speaker.map { "\($0.label): \(s.text)" } ?? s.text }
            .joined(separator: "\n")
    }

    /// Where `Resume` restarts decoding: the end of the last stored segment.
    var resumePosition: TimeInterval {
        segments.last?.end ?? 0
    }
}
