import AppKit
import Foundation

/// Opens a URL in the user's browser. Behind a protocol so models that link out can be
/// tested without a browser window appearing on a real desktop (invariant 2).
///
/// Kept separate from `FileRevealing`: revealing a local file in Finder and handing a URL to
/// the default handler are different capabilities, and a caller that only links out should not
/// gain the ability to reveal files.
@MainActor protocol URLOpening {
    func open(_ url: URL)
}

/// Thin `NSWorkspace` glue with no logic of its own; covered by `docs/SMOKE_TEST.md`
/// (invariant 3).
@MainActor final class NSWorkspaceURLOpener: URLOpening {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
