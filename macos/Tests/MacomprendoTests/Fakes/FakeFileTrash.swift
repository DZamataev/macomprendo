import Foundation
@testable import Macomprendo

/// Records what would have gone to the Trash; `failure` makes the next move throw.
@MainActor final class FakeFileTrash: FileTrashing {
    private(set) var trashed: [URL] = []
    var failure: (any Error)?

    func moveToTrash(_ url: URL) throws {
        if let failure {
            self.failure = nil
            throw failure
        }
        trashed.append(url)
    }
}
