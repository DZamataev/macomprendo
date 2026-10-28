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

    /// A call job runs its two tracks in turn, so the row has to say which side is being
    /// transcribed; a file job keeps the speakerless wording.
    @Test func progressTextNamesTheSpeakerOfACallTrack() {
        #expect(TranscriptsView.progressText(position: 760, duration: 3483, speaker: nil)
                == "Transcribing — 12:40 / 58:03")
        #expect(TranscriptsView.progressText(position: 760, duration: 3483, speaker: .me)
                == "Transcribing Me — 12:40 / 58:03")
        #expect(TranscriptsView.progressText(position: 760, duration: 3483, speaker: .others)
                == "Transcribing Others — 12:40 / 58:03")
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
            transcriptID: 7, title: "lecture.mp3", position: 0, duration: 10, speaker: nil)
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

    /// The delete confirmation names what its checkbox sends to the Trash.
    @Test func theDeleteCheckboxNamesTheSource() {
        #expect(TranscriptsView.deleteSourceTitle(for: .file)
                == "Also move the source file and its notes to the Trash")
        #expect(TranscriptsView.deleteSourceTitle(for: .call)
                == "Also move the call recording to the Trash")
    }

    // MARK: - Sticking to the bottom of a growing transcript

    @Test func aNewSegmentScrollsOnlyAPinnedViewOfTheSameTranscript() {
        let before = TranscriptsView.SegmentTail(transcriptID: 1, count: 4)
        let grown = TranscriptsView.SegmentTail(transcriptID: 1, count: 5)
        #expect(TranscriptsView.followsNewSegments(from: before, to: grown, pinned: true))
        #expect(!TranscriptsView.followsNewSegments(from: before, to: grown, pinned: false))
        // Opening another transcript is not new text.
        #expect(!TranscriptsView.followsNewSegments(
            from: before, to: TranscriptsView.SegmentTail(transcriptID: 2, count: 9), pinned: true))
        #expect(!TranscriptsView.followsNewSegments(from: grown, to: before, pinned: true))
    }

    @Test func scrollingDecidesThePinFromWhereTheBottomIs() {
        let viewport: CGFloat = 400
        let old = CGRect(x: 0, y: 0, width: 300, height: 1000)
        // Scrolled to the end: the content's bottom sits at the viewport's bottom.
        #expect(TranscriptsView.pinnedToBottom(
            wasPinned: false, old: old, new: CGRect(x: 0, y: -600, width: 300, height: 1000),
            viewportHeight: viewport))
        // Scrolled up away from it.
        #expect(!TranscriptsView.pinnedToBottom(
            wasPinned: true, old: old, new: CGRect(x: 0, y: -300, width: 300, height: 1000),
            viewportHeight: viewport))
    }

    @Test func growingContentKeepsThePinAsItWas() {
        let viewport: CGFloat = 400
        let atEnd = CGRect(x: 0, y: -600, width: 300, height: 1000)
        let grown = CGRect(x: 0, y: -600, width: 300, height: 1040)
        // A new row pushes the bottom out of view; that is the text growing, not the user
        // scrolling away, so a pinned view stays pinned and an unpinned one stays put.
        #expect(TranscriptsView.pinnedToBottom(wasPinned: true, old: atEnd, new: grown,
                                               viewportHeight: viewport))
        #expect(!TranscriptsView.pinnedToBottom(wasPinned: false, old: atEnd, new: grown,
                                                viewportHeight: viewport))
        // A short transcript that still fits is at its bottom however it got there.
        #expect(TranscriptsView.pinnedToBottom(
            wasPinned: false, old: CGRect(x: 0, y: 0, width: 300, height: 200),
            new: CGRect(x: 0, y: 0, width: 300, height: 240), viewportHeight: viewport))
    }
}
