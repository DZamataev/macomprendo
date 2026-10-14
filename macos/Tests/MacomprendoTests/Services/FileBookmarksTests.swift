import Foundation
import Testing
@testable import Macomprendo

@Suite("File bookmarks")
struct FileBookmarksTests {
    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileBookmarksTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("source.txt")
        try Data("source".utf8).write(to: file)
        return file
    }

    @Test func aBookmarkResolvesToTheSameFile() throws {
        let original = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let bookmarks = FoundationFileBookmarks()

        let resolved = try bookmarks.resolve(bookmarks.bookmark(for: original))

        #expect(resolved.standardizedFileURL.path == original.standardizedFileURL.path)
    }

    @Test func aBookmarkFollowsAMovedFile() throws {
        let original = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let moved = original.deletingLastPathComponent().appendingPathComponent("moved.txt")
        let bookmarks = FoundationFileBookmarks()
        let bookmark = try bookmarks.bookmark(for: original)
        try FileManager.default.moveItem(at: original, to: moved)

        let resolved = try bookmarks.resolve(bookmark)

        #expect(resolved.standardizedFileURL.path == moved.standardizedFileURL.path)
    }

    @Test func aDeletedFileIsUnavailable() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let bookmarks = FoundationFileBookmarks()
        let bookmark = try bookmarks.bookmark(for: file)
        try FileManager.default.removeItem(at: file)

        #expect(throws: MacomprendoError.sourceFileUnavailable) {
            try bookmarks.resolve(bookmark)
        }
    }

    @Test func garbageDataIsUnavailable() {
        let bookmarks = FoundationFileBookmarks()

        #expect(throws: MacomprendoError.sourceFileUnavailable) {
            try bookmarks.resolve(Data("not a bookmark".utf8))
        }
    }
}
