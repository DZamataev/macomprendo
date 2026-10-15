import Foundation
import Testing
@testable import Macomprendo

@Suite struct CallRecordingFoldersTests {
    let moscow = TimeZone(identifier: "Europe/Moscow")!
    // 2026-10-15 13:42:07 UTC == 16:42:07 MSK
    let date = Date(timeIntervalSince1970: 1_792_071_727)

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallRecordingFolders-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFolder(_ name: String, in root: URL, status: CallRecordingManifest.Status?)
        throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let status {
            var manifest = CallRecordingManifest(startedAt: date, folderName: name)
            manifest.status = status
            try manifest.write(to: folder)
        }
        return folder
    }

    @Test func createNamesTheFolderAfterTheStartTime() throws {
        let root = try tempDirectory().appendingPathComponent("recordings", isDirectory: true)
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)

        // The recordings directory itself is created if it is not there yet.
        let folder = try folders.create(in: root, startedAt: date)

        #expect(folder.lastPathComponent == "rec 2026-10-15 16-42-07")
        #expect(folder.path == root.appendingPathComponent("rec 2026-10-15 16-42-07").path)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }

    @Test func createSuffixesACollidingFolder() throws {
        let root = try tempDirectory()
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)

        let first = try folders.create(in: root, startedAt: date)
        let second = try folders.create(in: root, startedAt: date)
        let third = try folders.create(in: root, startedAt: date)

        #expect(first.lastPathComponent == "rec 2026-10-15 16-42-07")
        #expect(second.lastPathComponent == "rec 2026-10-15 16-42-07 (2)")
        #expect(third.lastPathComponent == "rec 2026-10-15 16-42-07 (3)")
        #expect(Set([first, second, third]).count == 3)
        for folder in [first, second, third] {
            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
        }
    }

    @Test func createThrowsWhenTheDirectoryCannotBeMade() throws {
        let root = try tempDirectory()
        let file = root.appendingPathComponent("a-file")
        try Data("not a folder".utf8).write(to: file)
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)

        #expect(throws: MacomprendoError.callRecordingLocationUnavailable) {
            try folders.create(in: file.appendingPathComponent("nested"), startedAt: date)
        }
    }

    @Test func unfinishedRecordingsKeepsOnlyRecordingStatus() throws {
        let root = try tempDirectory()
        _ = try makeFolder("recording", in: root, status: .recording)
        _ = try makeFolder("finished", in: root, status: .finished)
        _ = try makeFolder("no-manifest", in: root, status: nil)
        try Data("stray".utf8).write(to: root.appendingPathComponent("stray.txt"))
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)

        let found = folders.unfinishedRecordings(in: root)

        #expect(found.map(\.lastPathComponent) == ["recording"])
    }

    @Test func unfinishedRecordingsOfAMissingDirectoryIsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallRecordingFolders-\(UUID().uuidString)", isDirectory: true)
        #expect(FileSystemCallRecordingFolders().unfinishedRecordings(in: missing).isEmpty)
    }

    @Test func totalSizeSumsEveryRegularFileBelowTheDirectory() throws {
        let root = try tempDirectory()
        let nested = root.appendingPathComponent("rec x/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 10).write(to: nested.appendingPathComponent("ten.bin"))
        try Data(repeating: 0, count: 20).write(to: root.appendingPathComponent("twenty.bin"))
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)

        #expect(folders.totalSize(of: root) == 30)
        #expect(folders.totalSize(of: root.appendingPathComponent("missing")) == 0)
    }

    @Test func removeDeletesTheFolderAndToleratesAMissingOne() throws {
        let root = try tempDirectory()
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)
        let folder = try folders.create(in: root, startedAt: date)

        folders.remove(folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        folders.remove(folder) // best effort: a folder that is already gone is not a failure
    }
}
