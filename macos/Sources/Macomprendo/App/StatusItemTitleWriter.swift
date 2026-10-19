import Combine
import Foundation

/// The three inputs the status item's title derives from, each change delivered with its new
/// value. `@Published` emits in `willSet`, so re-reading the controllers inside a sink sees the
/// value being replaced — the final `.finished` of a job was read as `.running` and the title
/// stuck on the last clock.
enum StatusItemInputs {
    typealias Value = (recordingElapsed: TimeInterval?,
                       transcription: FileTranscriptionController.State)

    static func latest<R: Publisher, E: Publisher, T: Publisher>(
        isRecording: R, elapsed: E, transcription: T
    ) -> AnyPublisher<Value, Never>
    where R.Output == Bool, R.Failure == Never, E.Output == TimeInterval, E.Failure == Never,
          T.Output == FileTranscriptionController.State, T.Failure == Never {
        Publishers.CombineLatest3(isRecording, elapsed, transcription)
            .map { recording, elapsed, transcription in
                (recording ? elapsed : nil, transcription)
            }
            .eraseToAnyPublisher()
    }
}

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
/// activity can render at its current clock shape, so a percent gaining a digit or a clock
/// ticking cannot resize the button — the open popover hangs off that button and must not
/// re-anchor (spec §4). Crossing an hour widens it once.
enum StatusItemTitleSample {
    /// `TranscriptExporter.clock` with every digit position kept: the reserve grows only when
    /// the clock gains a field (MM:SS → H:MM:SS → HH:MM:SS), so a short call stays narrow
    /// enough to stay left of the notch. Digits are monospaced, so the values do not matter.
    nonisolated static func widestClock(shapeOf seconds: TimeInterval) -> TimeInterval {
        switch seconds {
        case ..<3600: 23 * 60 + 45
        case ..<36000: 3600 + 23 * 60 + 45
        default: 12 * 3600 + 23 * 60 + 45
        }
    }

    /// The presentation's own output for the same inputs with the numbers widened, so the
    /// sample and the rendered title can never drift apart.
    nonisolated static func widest(
        recordingElapsed: TimeInterval?,
        transcription: FileTranscriptionController.State
    ) -> String {
        MenuPanelPresentation.statusItem(
            recordingElapsed: recordingElapsed.map { widestClock(shapeOf: $0) },
            transcription: widened(transcription)).title
    }

    private nonisolated static func widened(
        _ state: FileTranscriptionController.State
    ) -> FileTranscriptionController.State {
        guard case let .running(transcriptID, title, _, duration, speaker) = state else { return state }
        guard speaker == nil else {
            // The position never passes the duration, so the duration's shape is final.
            let clock = widestClock(shapeOf: duration)
            return .running(transcriptID: transcriptID, title: title, position: clock,
                            duration: clock, speaker: speaker)
        }
        // Position equal to duration floors to the running cap: `"99%"`, the widest a file
        // job's percent ever renders.
        return .running(transcriptID: transcriptID, title: title, position: 100, duration: 100,
                        speaker: nil)
    }
}
