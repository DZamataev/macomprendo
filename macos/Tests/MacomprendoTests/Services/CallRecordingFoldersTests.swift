import Foundation
import Testing
@testable import Macomprendo

@Suite struct CallRecordingFoldersTests {
    let moscow = TimeZone(identifier: "Europe/Moscow")!
    // 2026-10-15 13:42:07 UTC == 16:42:07 MSK
    let date = Date(timeIntervalSince1970: 1_792_071_727)

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

    @Test func unfinishedRecordingsIgnoresAnUndecodableManifestAndKeepsScanning() throws {
        let root = try tempDirectory()
        let broken = try makeFolder("broken", in: root, status: nil)
        try Data("{not json".utf8).write(
            to: broken.appendingPathComponent(CallRecordingLayout.manifestFileName))
        _ = try makeFolder("recording", in: root, status: .recording)
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)

        let found = folders.unfinishedRecordings(in: root)

        #expect(found.map(\.lastPathComponent) == ["recording"])
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

    /// The call job's track check, so `Features` never touches the file system itself.
    @Test func fileExistsAnswersFromTheFileSystem() throws {
        let root = try tempDirectory()
        let folders = FileSystemCallRecordingFolders(timeZone: moscow)
        let file = root.appendingPathComponent("track.m4a")
        try Data().write(to: file)

        #expect(folders.fileExists(file))
        #expect(!folders.fileExists(root.appendingPathComponent("missing.m4a")))
    }
}

/// The fake stands in for the service in controller tests, so the part of it that touches real
/// disk (Task 8's `realDirectoryRoot` mode) has to behave like `FileSystemCallRecordingFolders`.
@Suite struct FakeCallRecordingFoldersTests {
    let moscow = TimeZone(identifier: "Europe/Moscow")!
    let date = Date(timeIntervalSince1970: 1_792_071_727)

    @Test func realRootCreateMakesTheServicesFolderWithItsTimeZone() throws {
        let root = try tempDirectory()
        let fake = FakeCallRecordingFolders(
            realDirectoryRoot: root, timeZone: TimeZone(identifier: "UTC")!)

        let folder = try fake.create(in: root, startedAt: date)

        // 2026-10-15 13:42:07 UTC — the fake's zone, not the machine's.
        #expect(folder.lastPathComponent == "rec 2026-10-15 13-42-07")
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func realRootCreateSuffixesACollisionLikeTheService() throws {
        let root = try tempDirectory()
        let fake = FakeCallRecordingFolders(realDirectoryRoot: root, timeZone: moscow)

        let first = try fake.create(in: root, startedAt: date)
        let second = try fake.create(in: root, startedAt: date)

        #expect(first.lastPathComponent == "rec 2026-10-15 16-42-07")
        #expect(second.lastPathComponent == "rec 2026-10-15 16-42-07 (2)")
        #expect(FileManager.default.fileExists(atPath: second.path))
    }

    @Test func realRootCreateReportsTheServicesErrorWhenTheRootCannotBeMade() throws {
        let outer = try tempDirectory()
        let file = outer.appendingPathComponent("a-file")
        try Data("not a folder".utf8).write(to: file)
        let root = file.appendingPathComponent("nested")
        let fake = FakeCallRecordingFolders(realDirectoryRoot: root, timeZone: moscow)

        #expect(throws: MacomprendoError.callRecordingLocationUnavailable) {
            try fake.create(in: root, startedAt: date)
        }
    }

    @Test func createErrorWinsOverTheRealRootOnce() throws {
        let root = try tempDirectory()
        let fake = FakeCallRecordingFolders(realDirectoryRoot: root, timeZone: moscow)
        fake.createError = MacomprendoError.callRecordingLocationUnavailable

        #expect(throws: MacomprendoError.callRecordingLocationUnavailable) {
            try fake.create(in: root, startedAt: date)
        }
        #expect(fake.created.isEmpty)

        let folder = try fake.create(in: root, startedAt: date)
        #expect(folder.lastPathComponent == "rec 2026-10-15 16-42-07")
        #expect(fake.created.map(\.directory) == [root])
    }

    @Test func removeDeletesTheRealFolderAndRecordsIt() throws {
        let root = try tempDirectory()
        let fake = FakeCallRecordingFolders(realDirectoryRoot: root, timeZone: moscow)
        let folder = try fake.create(in: root, startedAt: date)

        fake.remove(folder)

        #expect(fake.removed == [folder])
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func defaultModeTouchesNoDisk() throws {
        let root = try tempDirectory()
        let fake = FakeCallRecordingFolders(timeZone: moscow)

        let folder = try fake.create(in: root, startedAt: date)

        #expect(folder.lastPathComponent == "rec 2026-10-15 16-42-07")
        #expect(folder.path.hasPrefix(root.path + "/"))
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        #expect(fake.unfinished.isEmpty)
        #expect(fake.size == 0)
    }
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CallRecordingFolders-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
