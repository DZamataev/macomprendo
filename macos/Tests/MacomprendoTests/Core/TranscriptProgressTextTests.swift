import Foundation
import Testing
@testable import Macomprendo

/// The wording of a running transcription, shared by the Transcripts window's progress row,
/// the menubar panel's card and its status-item tooltip.
@Suite struct TranscriptProgressTextTests {

    @Test func aFileJobNamesThePositionAndDurationWithoutASpeaker() {
        #expect(TranscriptProgressText.progressText(position: 760, duration: 3483)
                == "Transcribing — 12:40 / 58:03")
    }

    @Test func aCallTrackNamesItsSpeaker() {
        #expect(TranscriptProgressText.progressText(position: 760, duration: 3483, speaker: .me)
                == "Transcribing Me — 12:40 / 58:03")
        #expect(TranscriptProgressText.progressText(position: 760, duration: 3483, speaker: .others)
                == "Transcribing Others — 12:40 / 58:03")
    }

    /// The clock pair the panel's card shows under its caption — position first, then the total.
    @Test func theClockPairRunsFromTheProcessedPositionToTheTotal() {
        #expect(TranscriptProgressText.clockText(position: 760, duration: 3483)
                == "12:40 / 58:03")
        #expect(TranscriptProgressText.clockText(position: 0, duration: 0)
                == "00:00 / 00:00")
        #expect(TranscriptProgressText.clockText(position: -1, duration: 3725)
                == "00:00 / 1:02:05")
    }
}
