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
    /// Which of the other participants spoke an `.others` segment of a call whose far side was
    /// told apart by voice: 1-based, numbered by first appearance. `nil` everywhere else.
    let voice: Int?

    init(start: TimeInterval, end: TimeInterval, text: String, rawText: String? = nil,
         speaker: TranscriptSpeaker? = nil, voice: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.rawText = rawText
        self.speaker = speaker
        self.voice = voice
    }

    /// What a transcript prints before the text: `Speaker 2` for a voice on the far side, else
    /// the side's own label (`Me`, `Others`), `nil` for a segment of no call. Only `.others`
    /// is ever told apart, so a voice on `Me` does not relabel the user.
    var speakerLabel: String? {
        guard let speaker else { return nil }
        if speaker == .others, let voice { return "Speaker \(voice)" }
        return speaker.label
    }
}

extension TranscriptHeader {
    func retitled(_ title: String) -> TranscriptHeader {
        TranscriptHeader(id: id, createdAt: createdAt, sourceKind: sourceKind, title: title,
                         duration: duration, status: status, statusReason: statusReason)
    }

    func withDuration(_ duration: TimeInterval?) -> TranscriptHeader {
        TranscriptHeader(id: id, createdAt: createdAt, sourceKind: sourceKind, title: title,
                         duration: duration, status: status, statusReason: statusReason)
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
        segments.map { s in s.speakerLabel.map { "\($0): \(s.text)" } ?? s.text }
            .joined(separator: "\n")
    }

    /// The same transcript with no text: what **Transcribe Again** starts from.
    var withoutSegments: Transcript {
        Transcript(header: header, run: run, sourceBookmark: sourceBookmark, summary: summary,
                   segments: [])
    }

    /// Where `Resume` restarts decoding: the end of the last stored segment.
    var resumePosition: TimeInterval {
        segments.last?.end ?? 0
    }
}
