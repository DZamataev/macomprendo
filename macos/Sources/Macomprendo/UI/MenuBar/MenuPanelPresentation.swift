import Foundation

/// The panel's presentation rules as pure functions: which activity text a controller state
/// produces and what the closed-panel status item reads. Kept free of AppKit and SwiftUI so
/// every rule is unit-tested without a running app, and so the noisy state publishers only
/// ever reach text.
enum MenuPanelPresentation {

    // MARK: - Dictation

    /// The conditional dictation line below the call block; `nil` while idle so the panel
    /// never prints a permanent readiness label.
    nonisolated static func dictationActivity(_ state: DictationState) -> String? {
        switch state {
        case .idle: nil
        case .recording: "Recording dictation…"
        case .transcribing: "Transcribing dictation…"
        case .inserting: "Inserting text…"
        case let .failed(message): message
        }
    }

    // MARK: - Shortcuts

    /// The shortcut shown beside a hotkey switch, or `nil` when none is assigned: an absent
    /// binding is omitted, never rendered as a placeholder.
    nonisolated static func shortcutAnnotation(_ shortcut: String?) -> String? {
        guard let trimmed = shortcut?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    // MARK: - Transcription activity

    struct TranscriptionActivity: Equatable, Sendable {
        enum Progress: Equatable, Sendable {
            case percent(Int)
            case indeterminate
        }

        let transcriptID: Int64?
        /// `nil` for a failure without a row to open.
        let title: String?
        let caption: String
        /// `"12:40 / 58:03"`, both ends on the call clock; `nil` for failures.
        let detail: String?
        /// `nil` for failures.
        let progress: Progress?
        let isFailure: Bool
    }

    /// `nil` for `.idle` and `.finished`: neither keeps a card in the panel.
    nonisolated static func transcriptionActivity(
        _ state: FileTranscriptionController.State
    ) -> TranscriptionActivity? {
        switch state {
        case .idle, .finished:
            return nil

        case let .failed(message, transcriptID):
            return TranscriptionActivity(
                transcriptID: transcriptID,
                title: nil,
                caption: message,
                detail: nil,
                progress: nil,
                isFailure: true)

        case let .running(transcriptID, title, position, duration, speaker):
            let progress: TranscriptionActivity.Progress
            if speaker == nil {
                progress = filePercent(position: position, duration: duration)
                    .map { .percent($0) } ?? .indeterminate
            } else {
                // A call's position and duration are one track shifted onto the call clock,
                // not whole-call completion, so their ratio is never shown as a percent.
                progress = .indeterminate
            }
            return TranscriptionActivity(
                transcriptID: transcriptID,
                title: title,
                caption: "Transcribing \(speaker?.label ?? "file")",
                detail: "\(TranscriptExporter.clock(position)) / "
                    + TranscriptExporter.clock(duration),
                progress: progress,
                isFailure: false)
        }
    }

    /// The file percent from `floor(clamp(position / duration) * 100)`, capped at 99 while
    /// running. `nil` — indeterminate — when the inputs cannot form a ratio, or when the
    /// duration is missing: a guess dressed as progress is worse than none.
    nonisolated static func filePercent(position: TimeInterval, duration: TimeInterval) -> Int? {
        guard position.isFinite, duration.isFinite, duration > 0 else { return nil }
        let ratio = min(max(position / duration, 0), 1)
        return min(99, Int((ratio * 100).rounded(.down)))
    }

    // MARK: - Status item

    struct StatusItemContent: Equatable, Sendable {
        enum Symbol: Equatable, Sendable {
            case idle
            case recording
        }

        let symbol: Symbol
        /// `""` when idle: the template image alone carries the idle state.
        let title: String
        let tooltip: String
        let accessibilityLabel: String
    }

    /// The status item while the popover is closed. A live recording always wins the symbol
    /// and leads the title, so a transcription update can never erase it; never a title or
    /// filename.
    nonisolated static func statusItem(
        recordingElapsed: TimeInterval?,
        transcription: FileTranscriptionController.State
    ) -> StatusItemContent {
        var lines = ["Macomprendo"]
        if let recordingElapsed {
            lines.append("Recording call — \(TranscriptExporter.clock(recordingElapsed))")
        }
        if case let .running(_, _, position, duration, speaker) = transcription {
            if let speaker {
                lines.append("Transcribing \(speaker.label) — \(TranscriptExporter.clock(position))"
                    + " / \(TranscriptExporter.clock(duration))")
            } else {
                let readable = filePercent(position: position, duration: duration)
                    .map { "\($0)%" } ?? "in progress"
                lines.append("Transcribing file — \(readable)")
            }
        }

        let symbol: StatusItemContent.Symbol = recordingElapsed == nil ? .idle : .recording
        let title: String
        switch (recordingElapsed, transcription) {
        case let (nil, .running(_, _, position, duration, speaker)):
            title = standbyTitle(position: position, duration: duration, speaker: speaker)
        case let (clock?, .running(_, _, position, duration, speaker)):
            // A call job contributes only an activity marker here: its speaker and clock live
            // in the tooltip and the panel, which have the room to name them.
            title = "\(TranscriptExporter.clock(clock)) · "
                + (speaker == nil
                    ? (filePercent(position: position, duration: duration).map { "\($0)%" } ?? "…")
                    : "…")
        case let (clock?, _):
            title = TranscriptExporter.clock(clock)
        case (nil, _):
            title = ""
        }

        return StatusItemContent(
            symbol: symbol,
            title: title,
            tooltip: lines.joined(separator: "\n"),
            accessibilityLabel: lines.joined(separator: ", "))
    }

    /// The title for a transcription with no recording beside it: a file's percent or
    /// ellipsis, or a call's speaker and processed clock.
    private nonisolated static func standbyTitle(position: TimeInterval, duration: TimeInterval,
                                                 speaker: TranscriptSpeaker?) -> String {
        if let speaker {
            return "\(speaker.label) \(TranscriptExporter.clock(position))"
        }
        return filePercent(position: position, duration: duration).map { "\($0)%" } ?? "…"
    }
}
