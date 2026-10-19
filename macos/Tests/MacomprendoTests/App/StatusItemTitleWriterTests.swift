import Combine
import Foundation
import Testing
@testable import Macomprendo

/// The status item's title is written only when the rendered value changes: the call
/// controller's elapsed clock publishes ten times a second, and every one of those ticks
/// recomputes the content (spec §4).
@MainActor
@Suite struct StatusItemTitleWriterTests {
    private func content(
        _ title: String,
        symbol: MenuPanelPresentation.StatusItemContent.Symbol = .idle
    ) -> MenuPanelPresentation.StatusItemContent {
        MenuPanelPresentation.StatusItemContent(
            symbol: symbol,
            title: title,
            tooltip: title.isEmpty ? "Macomprendo" : "Macomprendo\n\(title)",
            accessibilityLabel: title.isEmpty ? "Macomprendo" : "Macomprendo, \(title)")
    }

    @Test func theFirstContentReachesTheButton() {
        var written: [MenuPanelPresentation.StatusItemContent] = []
        let writer = StatusItemTitleWriter { written.append($0) }

        writer.apply(content(""))

        #expect(written == [content("")])
    }

    @Test func anIdenticalContentIsNotWrittenAgain() {
        var writes = 0
        let writer = StatusItemTitleWriter { _ in writes += 1 }

        writer.apply(content(""))
        writer.apply(content(""))
        writer.apply(content(""))

        #expect(writes == 1)
    }

    @Test func aChangedContentIsWritten() {
        var written: [MenuPanelPresentation.StatusItemContent] = []
        let writer = StatusItemTitleWriter { written.append($0) }

        writer.apply(content("", symbol: .idle))
        writer.apply(content("12:34", symbol: .recording))

        #expect(written.map(\.title) == ["", "12:34"])
        #expect(written.map(\.symbol) == [.idle, .recording])
    }

    /// A recording's clock ticks ten times a second; only the ticks whose rendered clock
    /// text actually moved reach the button.
    @Test func elapsedClockTicksOnlyWriteWhenTheClockTextMoves() {
        var written: [MenuPanelPresentation.StatusItemContent] = []
        let writer = StatusItemTitleWriter { written.append($0) }

        for elapsed in [10.0, 10.4, 10.8, 11.0, 11.9, 12.1] {
            writer.apply(MenuPanelPresentation.statusItem(recordingElapsed: elapsed,
                                                          transcription: .idle))
        }

        #expect(written.map(\.title) == ["00:10", "00:11", "00:12"])
    }
}

/// The sample the width reservation is measured from: the widest title the current
/// activity can render, so no digit-count change inside a mode can resize the button and
/// re-anchor the open popover (spec §4).
@MainActor
@Suite struct StatusItemTitleSampleTests {
    private func fileJob(percent position: TimeInterval,
                         of duration: TimeInterval) -> FileTranscriptionController.State {
        .running(transcriptID: 1, title: "podcast.m4a", position: position,
                 duration: duration, speaker: nil)
    }

    private func callJob(_ speaker: TranscriptSpeaker) -> FileTranscriptionController.State {
        .running(transcriptID: 1, title: "Call", position: 42, duration: 99, speaker: speaker)
    }

    @Test func anIdleStatusItemReservesNoTitle() {
        #expect(StatusItemTitleSample.widest(recordingElapsed: nil, transcription: .idle) == "")
        #expect(StatusItemTitleSample.widest(recordingElapsed: nil,
                                             transcription: .finished(transcriptID: 1)) == "")
        #expect(StatusItemTitleSample.widest(
            recordingElapsed: nil,
            transcription: .failed(message: "Failed.", transcriptID: nil)) == "")
    }

    @Test func aRecordingReservesOnlyTheClockShapeItHasReached() {
        #expect(StatusItemTitleSample.widest(recordingElapsed: 0, transcription: .idle)
                == "23:45")
        #expect(StatusItemTitleSample.widest(recordingElapsed: 3599, transcription: .idle)
                == "23:45")
        #expect(StatusItemTitleSample.widest(recordingElapsed: 3600, transcription: .idle)
                == "1:23:45")
        #expect(StatusItemTitleSample.widest(recordingElapsed: 36000, transcription: .idle)
                == "12:23:45")
    }

    @Test func aFileJobReservesAFullPercent() {
        #expect(StatusItemTitleSample.widest(recordingElapsed: nil,
                                             transcription: fileJob(percent: 9, of: 100))
                == "99%")
    }

    @Test func aCallJobKeepsItsSpeakerAndReservesItsDurationShape() {
        #expect(StatusItemTitleSample.widest(recordingElapsed: nil, transcription: callJob(.me))
                == "Me 23:45")
        #expect(StatusItemTitleSample.widest(recordingElapsed: nil,
                                             transcription: callJob(.others))
                == "Others 23:45")
    }

    @Test func aRecordingWithAFileJobReservesBothHalves() {
        #expect(StatusItemTitleSample.widest(recordingElapsed: 30,
                                             transcription: fileJob(percent: 9, of: 100))
                == "23:45 · 99%")
    }

    @Test func aRecordingWithACallJobReservesTheClockAndTheMarker() {
        #expect(StatusItemTitleSample.widest(recordingElapsed: 30,
                                             transcription: callJob(.others))
                == "23:45 · …")
    }
}

/// `@Published` emits in `willSet`, so a sink that re-reads the object sees the old value: the
/// status item kept "Others 1:21:01" after the call transcript had finished. The inputs must
/// carry each new value themselves.
@MainActor
@Suite struct StatusItemInputsTests {
    private final class Sources: ObservableObject {
        @Published var isRecording = false
        @Published var elapsed: TimeInterval = 0
        @Published var transcription: FileTranscriptionController.State = .idle
    }

    private let running = FileTranscriptionController.State.running(
        transcriptID: 1, title: "Call", position: 4861, duration: 4861, speaker: .others)

    @Test func theLastChangeIsDeliveredWithItsNewValue() {
        let sources = Sources()
        var received: [(TimeInterval?, FileTranscriptionController.State)] = []
        let subscription = StatusItemInputs.latest(isRecording: sources.$isRecording,
                                                   elapsed: sources.$elapsed,
                                                   transcription: sources.$transcription)
            .sink { received.append(($0.recordingElapsed, $0.transcription)) }
        defer { subscription.cancel() }

        sources.transcription = running
        sources.transcription = .finished(transcriptID: 1)

        #expect(received.last?.1 == .finished(transcriptID: 1))
    }

    @Test func aStoppedRecordingDropsItsClock() {
        let sources = Sources()
        var received: [TimeInterval?] = []
        let subscription = StatusItemInputs.latest(isRecording: sources.$isRecording,
                                                   elapsed: sources.$elapsed,
                                                   transcription: sources.$transcription)
            .sink { received.append($0.recordingElapsed) }
        defer { subscription.cancel() }

        sources.isRecording = true
        sources.elapsed = 12
        #expect(received.last == .some(12))
        sources.isRecording = false
        #expect(received.last == .some(nil))
    }
}
