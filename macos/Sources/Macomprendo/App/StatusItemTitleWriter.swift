import Foundation

/// Writes the status button's rendered content only when the rendered value changes.
/// `callRecording.$elapsed` publishes ten times a second while a call is being recorded and
/// every tick recomputes the content; only the ticks whose clock text actually moved reach
/// AppKit (spec §4).
@MainActor
final class StatusItemTitleWriter {
    private let apply: (MenuPanelPresentation.StatusItemContent) -> Void
    private var last: MenuPanelPresentation.StatusItemContent?

    init(apply: @escaping (MenuPanelPresentation.StatusItemContent) -> Void) {
        self.apply = apply
    }

    func apply(_ content: MenuPanelPresentation.StatusItemContent) {
        guard content != last else { return }
        last = content
        apply(content)
    }
}

/// The sample the status item's width is reserved from: the widest title the current
/// activity can render, so a percent gaining a digit or a clock reaching its hour cannot
/// resize the button — the open popover hangs off that button and must not re-anchor
/// (spec §4).
enum StatusItemTitleSample {
    /// Any clock short of a hundred hours fits two hour digits; `TranscriptExporter.clock`
    /// renders `H:MM:SS` only past an hour, so this is the widest shape a running recording
    /// can reach.
    nonisolated static let widestClock: TimeInterval = 12 * 3600 + 23 * 60 + 45

    /// The presentation's own output for the same inputs with the numbers widened, so the
    /// sample and the rendered title can never drift apart.
    nonisolated static func widest(
        recordingElapsed: TimeInterval?,
        transcription: FileTranscriptionController.State
    ) -> String {
        MenuPanelPresentation.statusItem(
            recordingElapsed: recordingElapsed.map { _ in widestClock },
            transcription: widened(transcription)).title
    }

    private nonisolated static func widened(
        _ state: FileTranscriptionController.State
    ) -> FileTranscriptionController.State {
        guard case let .running(transcriptID, title, _, _, speaker) = state else { return state }
        guard speaker == nil else {
            return .running(transcriptID: transcriptID, title: title, position: widestClock,
                            duration: widestClock, speaker: speaker)
        }
        // Position equal to duration floors to the running cap: `"99%"`, the widest a file
        // job's percent ever renders.
        return .running(transcriptID: transcriptID, title: title, position: 100, duration: 100,
                        speaker: nil)
    }
}
