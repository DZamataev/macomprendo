import Foundation
import Testing
@testable import Macomprendo

/// The Transcripts window's pure helpers: the labels it renders and the decision of what a
/// job's state asks of the list. (Task 13 review: the statics shipped without tests.)
@Suite struct TranscriptsViewLabelTests {
    private let run = TranscriptionRun(modelID: "large-v3-turbo", engine: "whisperCpp",
                                       language: "ru", appVersion: "1.0")

    private func header(id: Int64) -> TranscriptHeader {
        TranscriptHeader(id: id, createdAt: Date(timeIntervalSince1970: 0), sourceKind: .file,
                         title: "lecture.mp3", duration: 10, status: .inProgress,
                         statusReason: nil)
    }

    @Test func progressTextNamesThePositionAndDuration() {
        #expect(TranscriptsView.progressText(position: 760, duration: 3483)
                == "Transcribing — 12:40 / 58:03")
    }

    @Test func statusBadgeIsNilForAFinishedTranscript() {
        #expect(TranscriptsView.statusBadge(.inProgress) == "In progress")
        #expect(TranscriptsView.statusBadge(.incomplete) == "Incomplete")
        #expect(TranscriptsView.statusBadge(.complete) == nil)
    }

    @Test func runDescriptionJoinsModelEngineAndLanguage() {
        #expect(TranscriptsView.runDescription(run) == "large-v3-turbo · whisperCpp · ru")
        let automatic = TranscriptionRun(modelID: "base", engine: "whisperCpp", language: nil,
                                         appVersion: "1.0")
        #expect(TranscriptsView.runDescription(automatic) == "base · whisperCpp · Automatic")
    }

    @Test func captionIsDateDurationRunInThatOrder() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let text = TranscriptsView.caption(date: date, duration: 3725, run: run)
        // The run description contains separator characters of its own, so the order is
        // pinned by the prefix and the intact tail rather than by splitting on " · ".
        #expect(text.hasPrefix(date.formatted(date: .abbreviated, time: .shortened)
            + " · 1:02:05 · "))
        #expect(text.hasSuffix("large-v3-turbo · whisperCpp · ru"))
    }

    @Test func captionSkipsAMissingDuration() {
        let date = Date(timeIntervalSince1970: 1_000_000)
        let text = TranscriptsView.caption(date: date, duration: nil, run: run)
        #expect(text.hasPrefix(date.formatted(date: .abbreviated, time: .shortened) + " · "))
        #expect(text.hasSuffix("large-v3-turbo · whisperCpp · ru"))
        #expect(!text.contains("1:02:05"))
    }

    // MARK: - What a job's state asks of the list

    /// A job's row is created before its first segment, so the first `.running` state may
    /// arrive before any `transcriptsChanged` reload: the window reloads once so the row shows.
    @Test func aRunningJobWhoseRowIsMissingReloadsTheList() {
        let state = FileTranscriptionController.State.running(
            transcriptID: 7, title: "lecture.mp3", position: 0, duration: 10)
        #expect(TranscriptsView.listEffect(for: state, headers: []) == .reload)
        #expect(TranscriptsView.listEffect(for: state, headers: [header(id: 7)]) == .none)
        #expect(TranscriptsView.listEffect(for: state, headers: [header(id: 8)]) == .reload)
    }

    @Test func aFinishedJobIsReloadedAndSelected() {
        #expect(TranscriptsView.listEffect(for: .finished(transcriptID: 7), headers: [])
                == .reloadAndSelect(7))
    }

    @Test func idleAndFailedJobsReloadTheList() {
        #expect(TranscriptsView.listEffect(for: .idle, headers: []) == .reload)
        #expect(TranscriptsView.listEffect(for: .failed(message: "gone", transcriptID: 7),
                                           headers: []) == .reload)
    }
}
