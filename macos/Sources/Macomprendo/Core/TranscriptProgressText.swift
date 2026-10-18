import Foundation

/// The one wording for a running transcription, shared by the Transcripts window's progress
/// row, the menubar panel's card and its status-item tooltip, so the three cannot drift.
enum TranscriptProgressText {
    /// `Transcribing Me — 12:40 / 58:03`; a file job has no speaker and reads
    /// `Transcribing — 12:40 / 58:03`.
    nonisolated static func progressText(position: TimeInterval, duration: TimeInterval,
                                         speaker: TranscriptSpeaker? = nil) -> String {
        let side = speaker.map { " \($0.label)" } ?? ""
        return "Transcribing\(side) — \(clockText(position: position, duration: duration))"
    }

    /// `12:40 / 58:03` — the processed position and the total, on the same clock. The panel
    /// shows this under the card's caption rather than the whole sentence.
    nonisolated static func clockText(position: TimeInterval, duration: TimeInterval) -> String {
        "\(TranscriptExporter.clock(position)) / \(TranscriptExporter.clock(duration))"
    }
}
