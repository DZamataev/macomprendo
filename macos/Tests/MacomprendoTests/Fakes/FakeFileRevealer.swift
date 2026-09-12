import Foundation
@testable import Macomprendo

@MainActor final class FakeFileRevealer: FileRevealing {
    private(set) var revealed: [URL] = []

    func reveal(_ url: URL) {
        revealed.append(url)
    }
}
