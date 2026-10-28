import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranscriptSidecarsTests {
    private let folder = URL(fileURLWithPath: "/Recordings/rec 2026-10-15 16-42-07 (2)",
                             isDirectory: true)

    @Test func callSubtitlesAreNamedAfterTheFolderInsideIt() {
        #expect(TranscriptSidecars.subtitlesURL(callFolder: folder).path
                == "/Recordings/rec 2026-10-15 16-42-07 (2)/rec 2026-10-15 16-42-07 (2).srt")
    }

    @Test func callNotesAreNamedAfterTheFolderInsideIt() {
        #expect(TranscriptSidecars.notesURL(callFolder: folder).path
                == "/Recordings/rec 2026-10-15 16-42-07 (2)/rec 2026-10-15 16-42-07 (2).notes.txt")
    }

    @Test func fileNotesReplaceOnlyTheLastExtension() {
        #expect(TranscriptSidecars.notesURL(sourceFile: URL(fileURLWithPath: "/a/meeting.mp4")).path
                == "/a/meeting.notes.txt")
        #expect(TranscriptSidecars.notesURL(sourceFile: URL(fileURLWithPath: "/a/v1.2 talk.m4a")).path
                == "/a/v1.2 talk.notes.txt")
        #expect(TranscriptSidecars.notesURL(sourceFile: URL(fileURLWithPath: "/a/README")).path
                == "/a/README.notes.txt")
    }

    @Test func notesForATranscriptFollowItsKind() {
        #expect(TranscriptSidecars.notesURL(kind: .call, source: folder)
                == TranscriptSidecars.notesURL(callFolder: folder))
        let file = URL(fileURLWithPath: "/a/meeting.mp4")
        #expect(TranscriptSidecars.notesURL(kind: .file, source: file)
                == TranscriptSidecars.notesURL(sourceFile: file))
    }
}
