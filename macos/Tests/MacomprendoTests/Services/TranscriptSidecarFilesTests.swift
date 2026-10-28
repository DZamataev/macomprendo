import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranscriptSidecarFilesTests {
    private let files = FileSystemTranscriptSidecars()

    @Test func missingNotesReadAsEmpty() throws {
        let root = try tempDirectory()
        #expect(try files.readNotes(at: root.appendingPathComponent("x.notes.txt")) == "")
    }

    @Test func notesRoundTripExactly() throws {
        let url = try tempDirectory().appendingPathComponent("rec.notes.txt")
        let text = "https://example.com/doc\nПовестка: Q4  \n"
        try files.saveNotes(text, at: url)
        #expect(try files.readNotes(at: url) == text)
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    @Test func blankNotesRemoveTheFileAndNeverCreateOne() throws {
        let root = try tempDirectory()
        let url = root.appendingPathComponent("rec.notes.txt")
        try files.saveNotes(" \n", at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        try files.saveNotes("link", at: url)
        try files.saveNotes("", at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func notesThatAreNotUTF8AreUnreadableNotEmpty() throws {
        let url = try tempDirectory().appendingPathComponent("rec.notes.txt")
        try Data([0xFF, 0xFE, 0xFD]).write(to: url)
        #expect(throws: MacomprendoError.self) { try files.readNotes(at: url) }
        do {
            _ = try files.readNotes(at: url)
        } catch let error as MacomprendoError {
            guard case .notesUnreadable = error else {
                Issue.record("expected notesUnreadable, got \(error)")
                return
            }
        }
    }

    @Test func savingNeverCreatesAMissingFolder() throws {
        let gone = try tempDirectory().appendingPathComponent("gone", isDirectory: true)
        let url = gone.appendingPathComponent("rec.notes.txt")
        do {
            try files.saveNotes("link", at: url)
            Issue.record("expected notesNotSaved")
        } catch let error as MacomprendoError {
            guard case .notesNotSaved = error else {
                Issue.record("expected notesNotSaved, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func subtitlesOverwriteAndNeverCreateAMissingFolder() throws {
        let root = try tempDirectory()
        let url = root.appendingPathComponent("rec.srt")
        try files.writeSubtitles("1\nold\n", at: url)
        try files.writeSubtitles("1\nnew\n", at: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "1\nnew\n")

        let gone = root.appendingPathComponent("gone", isDirectory: true)
        do {
            try files.writeSubtitles("1\n", at: gone.appendingPathComponent("rec.srt"))
            Issue.record("expected callSubtitlesNotSaved")
        } catch let error as MacomprendoError {
            guard case .callSubtitlesNotSaved = error else {
                Issue.record("expected callSubtitlesNotSaved, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: gone.path))
    }

    @Test func aSymlinkedFolderAndItsTargetShareOneCanonicalURL() throws {
        let root = try tempDirectory()
        let real = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("rec A"),
                                                withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        // The notes file itself need not exist yet.
        let viaAlias = alias.appendingPathComponent("rec A/rec A.notes.txt")
        let viaReal = real.appendingPathComponent("rec A/rec A.notes.txt")
        #expect(files.canonical(viaAlias) == files.canonical(viaReal))
        #expect(files.canonical(viaAlias).lastPathComponent == "rec A.notes.txt")
    }

    @Test func existenceIsAnsweredFromDisk() throws {
        let url = try tempDirectory().appendingPathComponent("rec.notes.txt")
        #expect(!files.fileExists(url))
        try files.saveNotes("x", at: url)
        #expect(files.fileExists(url))
    }
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptSidecars-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
