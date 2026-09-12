import AppKit
import Foundation

/// Shows a file or folder to the user in Finder. Behind a protocol so the settings model can
/// be tested without AppKit selecting anything on a real desktop (invariant 2).
@MainActor protocol FileRevealing {
    func reveal(_ url: URL)
}

/// Thin `NSWorkspace` glue with no logic of its own; covered by `docs/SMOKE_TEST.md`
/// (invariant 3).
@MainActor final class NSWorkspaceFileRevealer: FileRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
    }
}
