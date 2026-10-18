import Foundation

/// Moves a file or folder to the user's Trash, where it can still be put back. Behind a
/// protocol so the transcript library can be tested without touching a real file (invariant 2).
@MainActor protocol FileTrashing {
    func moveToTrash(_ url: URL) throws
}

/// Thin `FileManager` glue with no logic of its own; covered by `docs/SMOKE_TEST.md`
/// (invariant 3).
@MainActor final class FileManagerTrash: FileTrashing {
    func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }
}
