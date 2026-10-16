import Foundation

/// The recordings directory on disk: create a folder for one recording, find folders a previous
/// launch left unfinished, and measure how much space they use. Behind a protocol so a controller
/// never has to touch the file system in a test (invariant 2).
protocol CallRecordingFolderManaging: Sendable {
    /// Creates `<directory>/<rec …>` (creating `directory` too), adding " (2)"… on collision.
    /// Throws `callRecordingLocationUnavailable`.
    func create(in directory: URL, startedAt: Date) throws -> URL
    /// Folders directly inside `directory` whose manifest status is `.recording`.
    func unfinishedRecordings(in directory: URL) -> [URL]
    /// Bytes of every regular file under `directory`; 0 when it does not exist.
    func totalSize(of directory: URL) -> Int64
    /// Removes a folder this service created. Best effort.
    func remove(_ folder: URL)
    /// Whether a file exists at `url`. The call job's track check, behind this protocol so no
    /// `Features` controller touches the file system itself (invariant 2).
    func fileExists(_ url: URL) -> Bool
}

struct FileSystemCallRecordingFolders: CallRecordingFolderManaging {
    private let timeZone: TimeZone

    init(timeZone: TimeZone = .current) {
        self.timeZone = timeZone
    }

    func create(in directory: URL, startedAt: Date) throws -> URL {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // A parent that is a regular file, no permission, a full disk — all the same to the user.
            throw MacomprendoError.callRecordingLocationUnavailable
        }

        let base = CallRecordingLayout.baseName(startedAt: startedAt, timeZone: timeZone)
        for attempt in 1...999 {
            let folder = directory.appendingPathComponent(
                CallRecordingLayout.folderName(base: base, attempt: attempt), isDirectory: true)
            do {
                // `false`: an existing name must fail so the loop can try the next suffix.
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                continue
            } catch {
                throw MacomprendoError.callRecordingLocationUnavailable
            }
        }
        throw MacomprendoError.callRecordingLocationUnavailable
    }

    func unfinishedRecordings(in directory: URL) -> [URL] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return children.filter { child in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let manifest = try? CallRecordingManifest.read(from: child) else { return false }
            return manifest.status == .recording
        }
    }

    func totalSize(of directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder)
    }

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }
}
