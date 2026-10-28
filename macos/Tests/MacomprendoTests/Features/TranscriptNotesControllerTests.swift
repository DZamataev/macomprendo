import Foundation
import Testing
@testable import Macomprendo

@MainActor
@Suite struct TranscriptNotesControllerTests {
    private let a = URL(fileURLWithPath: "/Recordings/rec A/rec A.notes.txt")
    private let b = URL(fileURLWithPath: "/files/meeting.notes.txt")

    private func make(_ files: FakeTranscriptSidecars = FakeTranscriptSidecars())
        -> (TranscriptNotesController, FakeTranscriptSidecars) {
        (TranscriptNotesController(files: files, sleep: { _ in }), files)
    }

    @Test func loadReadsTheFileAndAMissingOneIsEmpty() {
        let (notes, files) = make()
        files.put("link", at: a)
        notes.load(a)
        notes.load(b)
        #expect(notes.text(for: a) == "link")
        #expect(notes.text(for: b) == "")
        #expect(notes.isEditable(a))
        #expect(notes.isEditable(b))
        #expect(notes.error(for: a) == nil)
    }

    @Test func anEditIsSavedAfterTheDelayWithTheLatestText() async {
        let (notes, files) = make()
        notes.load(a)
        notes.edit("h", for: a)
        notes.edit("https://x", for: a)
        await notes.drain()
        #expect(files.savedNotes.map(\.text) == ["https://x"])
        #expect(files.contents(a) == "https://x")
        #expect(notes.state(for: a) == .clean)
    }

    @Test func aDirtyDraftSurvivesAReload() {
        let (notes, files) = make()
        notes.load(a)
        notes.edit("unsaved", for: a)
        files.put("from another editor", at: a)
        notes.load(a)
        #expect(notes.text(for: a) == "unsaved")
        #expect(notes.state(for: a) == .dirty)
    }

    @Test func aCleanEntryIsReReadOnLoad() {
        let (notes, files) = make()
        notes.load(a)
        files.put("edited in TextEdit", at: a)
        notes.load(a)
        #expect(notes.text(for: a) == "edited in TextEdit")
    }

    @Test func twoEditorsOfOneFileShareOneDraft() async {
        let (notes, files) = make()
        notes.load(a)
        notes.edit("from the panel", for: a)
        notes.load(a) // the Transcripts window opens the same call
        #expect(notes.text(for: a) == "from the panel")
        notes.edit("from the panel\nand the window", for: a)
        await notes.drain()
        #expect(files.contents(a) == "from the panel\nand the window")
    }

    @Test func unreadableNotesAreReadOnlyAndNeverOverwritten() async {
        let (notes, files) = make()
        files.put("binary", at: a)
        files.readFailures = [a.path]
        notes.load(a)
        #expect(!notes.isEditable(a))
        #expect(notes.error(for: a)
                == ErrorText.describe(MacomprendoError.notesUnreadable("the file is not UTF-8 text")))
        notes.edit("typed anyway", for: a)
        notes.flush(a)
        await notes.drain()
        #expect(files.savedNotes.isEmpty)
        #expect(files.contents(a) == "binary")
    }

    @Test func aRepairedFileBecomesEditableOnTheNextLoad() {
        let (notes, files) = make()
        files.readFailures = [a.path]
        notes.load(a)
        files.readFailures = []
        files.put("fixed", at: a)
        notes.load(a)
        #expect(notes.isEditable(a))
        #expect(notes.text(for: a) == "fixed")
        #expect(notes.error(for: a) == nil)
    }

    @Test func anUnloadedFileIgnoresEdits() async {
        let (notes, files) = make()
        notes.edit("x", for: a)
        await notes.drain()
        #expect(files.savedNotes.isEmpty)
        #expect(notes.text(for: a) == "")
    }

    @Test func aFailedSaveKeepsTheDraftDirtyAndARetrySucceeds() async {
        let (notes, files) = make()
        notes.load(a)
        files.saveFailures = [a.path]
        notes.edit("link", for: a)
        await notes.drain()
        #expect(notes.state(for: a) == .dirty)
        #expect(notes.text(for: a) == "link")
        #expect(notes.error(for: a)
                == ErrorText.describe(MacomprendoError.notesNotSaved("the folder no longer exists")))

        files.saveFailures = []
        notes.flush(a)
        #expect(notes.state(for: a) == .clean)
        #expect(notes.error(for: a) == nil)
        #expect(files.contents(a) == "link")
    }

    @Test func errorsBelongToTheirOwnFile() async {
        let (notes, files) = make()
        notes.load(a)
        notes.load(b)
        files.saveFailures = [a.path]
        notes.edit("a", for: a)
        notes.edit("b", for: b)
        await notes.drain()
        #expect(notes.error(for: a) != nil)
        #expect(notes.error(for: b) == nil)
        #expect(files.contents(b) == "b")
    }

    @Test func flushWritesAtOnceAndFlushAllReportsFailures() {
        let (notes, files) = make()
        notes.load(a)
        notes.load(b)
        files.saveFailures = [b.path]
        notes.edit("a", for: a)
        notes.edit("b", for: b)
        let failures = notes.flushAll()
        #expect(files.contents(a) == "a")
        #expect(failures.keys.map(\.path) == [b.path])
    }

    @Test func discardForgetsTheDraftAndCancelsItsSave() async {
        let (notes, files) = make()
        notes.load(a)
        notes.edit("x", for: a)
        notes.discard(a)
        await notes.drain()
        #expect(files.savedNotes.isEmpty)
        #expect(notes.state(for: a) == nil)
        // A late editor close on a retired file writes nothing.
        notes.flush(a)
        notes.edit("y", for: a)
        await notes.drain()
        #expect(files.savedNotes.isEmpty)
    }

    @Test func currentTextPrefersTheDraftElseReadsTheDisk() throws {
        let (notes, files) = make()
        files.put("on disk", at: a)
        #expect(try notes.currentText(for: a) == "on disk")
        notes.edit("draft", for: a)
        #expect(try notes.currentText(for: a) == "draft")

        files.put("other", at: b)
        files.readFailures = [b.path]
        #expect(throws: MacomprendoError.self) { try notes.currentText(for: b) }
    }

    @Test func anUnreadableFileFailsAnActionWithTheSameErrorTheEditorShows() {
        let (notes, files) = make()
        files.put("binary", at: a)
        files.readFailures = [a.path]
        #expect(throws: MacomprendoError.notesUnreadable("the file is not UTF-8 text")) {
            try notes.currentText(for: a)
        }
        #expect(notes.error(for: a)
                == ErrorText.describe(MacomprendoError.notesUnreadable("the file is not UTF-8 text")))
    }

    /// The panel names a call's folder as the recordings directory spells it; the library
    /// resolves a bookmark, which follows symlinks. Both reach one entry.
    @Test func twoSpellingsOfOneFileShareOneEntry() async {
        let files = FakeTranscriptSidecars()
        files.aliases = ["/Users/test/Calls": "/Volumes/Data/Calls"]
        let (notes, _) = make(files)
        let viaAlias = URL(fileURLWithPath: "/Users/test/Calls/rec A/rec A.notes.txt")
        let resolved = URL(fileURLWithPath: "/Volumes/Data/Calls/rec A/rec A.notes.txt")
        notes.load(viaAlias)
        notes.edit("from the panel", for: viaAlias)
        notes.load(resolved)
        #expect(notes.text(for: resolved) == "from the panel")
        notes.discard(resolved)
        await notes.drain()
        #expect(files.savedNotes.isEmpty)
        #expect(notes.state(for: viaAlias) == nil)
    }

    @Test func hasNotesFollowsTheTrimmedText() {
        let (notes, files) = make()
        files.put(" \n", at: a)
        notes.load(a)
        #expect(!notes.hasNotes(a))
        notes.edit("x", for: a)
        #expect(notes.hasNotes(a))
    }
}
