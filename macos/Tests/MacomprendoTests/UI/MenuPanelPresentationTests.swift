import Foundation
import Testing
@testable import Macomprendo

@Suite struct MenuPanelPresentationTests {

    // MARK: - Dictation activity line (§3 non-idle dictation)

    @Test func idleDictationShowsNoActivityLine() {
        #expect(MenuPanelPresentation.dictationActivity(.idle) == nil)
    }

    @Test func eachNonIdleDictationStateNamesItsActivity() {
        #expect(MenuPanelPresentation.dictationActivity(.recording) == "Recording dictation…")
        #expect(MenuPanelPresentation.dictationActivity(.transcribing) == "Transcribing dictation…")
        #expect(MenuPanelPresentation.dictationActivity(.inserting) == "Inserting text…")
    }

    @Test func aFailedDictationShowsItsOwnMessage() {
        #expect(MenuPanelPresentation.dictationActivity(.failed("Microphone access is required"))
                == "Microphone access is required")
    }

    // MARK: - Shortcut annotation

    @Test func anAbsentShortcutIsOmittedRatherThanPlaceheld() {
        #expect(MenuPanelPresentation.shortcutAnnotation(nil) == nil)
        #expect(MenuPanelPresentation.shortcutAnnotation("") == nil)
        #expect(MenuPanelPresentation.shortcutAnnotation("  ") == nil)
    }

    @Test func aBoundShortcutIsShownTrimmed() {
        #expect(MenuPanelPresentation.shortcutAnnotation("⌃D") == "⌃D")
        #expect(MenuPanelPresentation.shortcutAnnotation(" ⌥Space ") == "⌥Space")
    }

    // MARK: - File percent

    @Test func filePercentFloorsClampsAndCapsAtNinetyNine() {
        #expect(MenuPanelPresentation.filePercent(position: 0, duration: 100) == 0)
        #expect(MenuPanelPresentation.filePercent(position: 42.7, duration: 100) == 42)
        #expect(MenuPanelPresentation.filePercent(position: 100, duration: 100) == 99)
        #expect(MenuPanelPresentation.filePercent(position: 150, duration: 100) == 99)
        #expect(MenuPanelPresentation.filePercent(position: -5, duration: 100) == 0)
    }

    @Test func anInvalidRatioIsIndeterminateNotGuessed() {
        #expect(MenuPanelPresentation.filePercent(position: 10, duration: 0) == nil)
        #expect(MenuPanelPresentation.filePercent(position: 10, duration: -1) == nil)
        #expect(MenuPanelPresentation.filePercent(position: .nan, duration: 100) == nil)
        #expect(MenuPanelPresentation.filePercent(position: 10, duration: .infinity) == nil)
    }

    // MARK: - Transcription activity

    @Test func idleAndFinishedTranscriptionsHaveNoCard() {
        #expect(MenuPanelPresentation.transcriptionActivity(.idle) == nil)
        #expect(MenuPanelPresentation.transcriptionActivity(.finished(transcriptID: 5)) == nil)
    }

    @Test func aFileJobReportsItsTitleCaptionDetailAndPercent() {
        let activity = MenuPanelPresentation.transcriptionActivity(
            .running(transcriptID: 5, title: "meeting.m4a", position: 42, duration: 100,
                     speaker: nil))
        #expect(activity == MenuPanelPresentation.TranscriptionActivity(
            transcriptID: 5,
            title: "meeting.m4a",
            caption: "Transcribing file",
            detail: "00:42 / 01:40",
            progress: .percent(42),
            isFailure: false))
    }

    @Test func aFileJobWithAnUnusableDurationIsIndeterminate() {
        let activity = MenuPanelPresentation.transcriptionActivity(
            .running(transcriptID: 5, title: "meeting.m4a", position: 10, duration: 0,
                     speaker: nil))
        #expect(activity?.progress == .indeterminate)
    }

    @Test func aCallJobNamesItsSpeakerAndNeverPresentsAPercent() {
        let me = MenuPanelPresentation.transcriptionActivity(
            .running(transcriptID: 7, title: "Call", position: 760, duration: 3483,
                     speaker: .me))
        #expect(me == MenuPanelPresentation.TranscriptionActivity(
            transcriptID: 7,
            title: "Call",
            caption: "Transcribing Me",
            detail: "12:40 / 58:03",
            progress: .indeterminate,
            isFailure: false))

        let others = MenuPanelPresentation.transcriptionActivity(
            .running(transcriptID: 7, title: "Call", position: 760, duration: 3483,
                     speaker: .others))
        #expect(others?.caption == "Transcribing Others")
        #expect(others?.progress == .indeterminate)
    }

    @Test func identifyingSpeakersIsAnIndeterminateCardWithoutAClock() {
        let card = MenuPanelPresentation.transcriptionActivity(
            .identifyingSpeakers(transcriptID: 7, title: "Call"))
        #expect(card == MenuPanelPresentation.TranscriptionActivity(
            transcriptID: 7,
            title: "Call",
            caption: "Identifying speakers…",
            detail: nil,
            progress: .indeterminate,
            isFailure: false))
    }

    @Test func identifyingSpeakersShowsAnEllipsisAndSaysSoInTheTooltip() {
        let alone = statusItem(nil, .identifyingSpeakers(transcriptID: 7, title: "Call"))
        #expect(alone.title == "…")
        #expect(alone.tooltip == "Macomprendo\nIdentifying call speakers…")
        let recording = statusItem(12, .identifyingSpeakers(transcriptID: 7, title: "Call"))
        #expect(recording.symbol == .recording)
        #expect(recording.title == "00:12 · …")
    }

    @Test func aFailureIsReportedWithItsMessageAndNoRow() {
        let withoutRow = MenuPanelPresentation.transcriptionActivity(
            .failed(message: "No speech found.", transcriptID: nil))
        #expect(withoutRow == MenuPanelPresentation.TranscriptionActivity(
            transcriptID: nil,
            title: nil,
            caption: "No speech found.",
            detail: nil,
            progress: nil,
            isFailure: true))

        let withRow = MenuPanelPresentation.transcriptionActivity(
            .failed(message: "Source file unavailable.", transcriptID: 12))
        #expect(withRow?.transcriptID == 12)
        #expect(withRow?.isFailure == true)
        #expect(withRow?.title == nil)
    }

    // MARK: - Status item (§4 table)

    private func statusItem(_ recording: TimeInterval?,
                            _ transcription: FileTranscriptionController.State)
        -> MenuPanelPresentation.StatusItemContent {
        MenuPanelPresentation.statusItem(recordingElapsed: recording, transcription: transcription)
    }

    @Test func idleWritesNoIdleTextAndOnlyNamesTheApp() {
        for state: FileTranscriptionController.State in [.idle, .finished(transcriptID: 1),
                                                         .failed(message: "No speech found.",
                                                                 transcriptID: nil)] {
            let content = statusItem(nil, state)
            #expect(content.symbol == .idle)
            #expect(content.title == "")
            #expect(content.tooltip == "Macomprendo")
            #expect(content.accessibilityLabel == "Macomprendo")
        }
    }

    @Test func aFileTranscriptionAloneShowsItsIntegerPercent() {
        let content = statusItem(nil, .running(transcriptID: 5, title: "meeting.m4a",
                                               position: 42, duration: 100, speaker: nil))
        #expect(content.symbol == .idle)
        #expect(content.title == "42%")
        #expect(content.tooltip == "Macomprendo\nTranscribing file — 42%")
        #expect(content.accessibilityLabel == "Macomprendo, Transcribing file — 42%")
    }

    @Test func aFileTranscriptionWithNoRatioShowsAnEllipsis() {
        let content = statusItem(nil, .running(transcriptID: 5, title: "meeting.m4a",
                                               position: 10, duration: 0, speaker: nil))
        #expect(content.title == "…")
        #expect(content.tooltip == "Macomprendo\nTranscribing file — in progress")
    }

    @Test func aCallTranscriptionAloneNamesTheSpeakerAndPosition() {
        let content = statusItem(nil, .running(transcriptID: 7, title: "Call", position: 760,
                                               duration: 3483, speaker: .me))
        #expect(content.symbol == .idle)
        #expect(content.title == "Me 12:40")
        #expect(content.tooltip == "Macomprendo\nTranscribing Me — 12:40 / 58:03")
        #expect(content.accessibilityLabel == "Macomprendo, Transcribing Me — 12:40 / 58:03")
    }

    @Test func recordingAloneShowsTheRecordingClock() {
        let content = statusItem(12, .idle)
        #expect(content.symbol == .recording)
        #expect(content.title == "00:12")
        #expect(content.tooltip == "Macomprendo\nRecording call — 00:12")
        #expect(content.accessibilityLabel == "Macomprendo, Recording call — 00:12")
    }

    @Test func recordingAndAFileTranscriptionKeepTheClockFirst() {
        let content = statusItem(12, .running(transcriptID: 5, title: "meeting.m4a",
                                              position: 42, duration: 100, speaker: nil))
        #expect(content.symbol == .recording)
        #expect(content.title == "00:12 · 42%")
        #expect(content.tooltip == "Macomprendo\nRecording call — 00:12\nTranscribing file — 42%")
    }

    @Test func recordingAndAnIndeterminateFileTranscriptionUseAnEllipsis() {
        let content = statusItem(12, .running(transcriptID: 5, title: "meeting.m4a",
                                              position: 10, duration: 0, speaker: nil))
        #expect(content.title == "00:12 · …")
        #expect(content.tooltip == "Macomprendo\nRecording call — 00:12\nTranscribing file — in progress")
    }

    @Test func aCallTrackTransitionCannotEraseTheRecordingIndicator() {
        let me = statusItem(12, .running(transcriptID: 7, title: "Call", position: 760,
                                         duration: 3483, speaker: .me))
        let others = statusItem(12, .running(transcriptID: 7, title: "Call", position: 760,
                                             duration: 3483, speaker: .others))
        #expect(me.symbol == .recording)
        #expect(me.title == "00:12 · …")
        #expect(others.symbol == .recording)
        #expect(others.title == "00:12 · …")
        #expect(others.tooltip
                == "Macomprendo\nRecording call — 00:12\nTranscribing Others — 12:40 / 58:03")
    }

    /// "Translate into" alone told a new user nothing about where the language is used.
    @Test func theTranslationSelectorSaysWhereItApplies() {
        #expect(MenuPanelPresentation.translationCaption == "Translation language for Refine & Summarize")
        #expect(MenuPanelPresentation.translationHelp.contains("Translate"))
        #expect(MenuPanelPresentation.translationHelp.contains("Summarize"))
    }
}
