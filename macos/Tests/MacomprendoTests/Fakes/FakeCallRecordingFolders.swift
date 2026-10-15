import Foundation
@testable import Macomprendo

/// In-memory `CallRecordingFolderManaging` for the controller and recovery tests.
///
/// By default it touches no disk and hands back a synthetic `<directory>/<folder name>` URL. Pass
/// `realDirectoryRoot` to have `create` make a real folder under that root instead, so a controller
/// under test can write and read a real `recording.json` there without a user folder being involved.
final class FakeCallRecordingFolders: CallRecordingFolderManaging, @unchecked Sendable {
    private let lock = NSLock()
    private let realDirectoryRoot: URL?

    private var createdDirectories: [(directory: URL, startedAt: Date)] = []
    private var createdFolders: [URL] = []
    private var nextCreateError: (any Error)?
    private var unfinishedFolders: [URL] = []
    private var directorySize: Int64 = 0
    private var removedFolders: [URL] = []

    init(realDirectoryRoot: URL? = nil) {
        self.realDirectoryRoot = realDirectoryRoot
    }

    /// The `directory` each `create` was asked for, with its start date, in order.
    var created: [(directory: URL, startedAt: Date)] { lock.withLock { createdDirectories } }
    /// The folders `create` handed back, in order.
    var folders: [URL] { lock.withLock { createdFolders } }
    /// Makes the next `create` throw, then clears itself.
    var createError: (any Error)? {
        get { lock.withLock { nextCreateError } }
        set { lock.withLock { nextCreateError = newValue } }
    }
    /// What `unfinishedRecordings` reports.
    var unfinished: [URL] {
        get { lock.withLock { unfinishedFolders } }
        set { lock.withLock { unfinishedFolders = newValue } }
    }
    /// What `totalSize` reports.
    var size: Int64 {
        get { lock.withLock { directorySize } }
        set { lock.withLock { directorySize = newValue } }
    }
    /// The folders `remove` was given, in order.
    var removed: [URL] { lock.withLock { removedFolders } }

    func create(in directory: URL, startedAt: Date) throws -> URL {
        if let error = lock.withLock({ let pending = nextCreateError; nextCreateError = nil; return pending }) {
            throw error
        }
        let folder: URL
        if let root = realDirectoryRoot {
            folder = try Self.createRealFolder(in: root, startedAt: startedAt)
        } else {
            folder = directory.appendingPathComponent(
                CallRecordingLayout.baseName(startedAt: startedAt), isDirectory: true)
        }
        lock.withLock {
            createdDirectories.append((directory, startedAt))
            createdFolders.append(folder)
        }
        return folder
    }

    func unfinishedRecordings(in directory: URL) -> [URL] {
        lock.withLock { unfinishedFolders }
    }

    func totalSize(of directory: URL) -> Int64 {
        lock.withLock { directorySize }
    }

    func remove(_ folder: URL) {
        lock.withLock { removedFolders.append(folder) }
        if realDirectoryRoot != nil {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static func createRealFolder(in root: URL, startedAt: Date) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let base = CallRecordingLayout.baseName(startedAt: startedAt)
        for attempt in 1...999 {
            let folder = root.appendingPathComponent(
                CallRecordingLayout.folderName(base: base, attempt: attempt), isDirectory: true)
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch let error as NSError where error.code == NSFileWriteFileExistsError {
                continue
            }
        }
        throw MacomprendoError.callRecordingLocationUnavailable
    }
}
