import Foundation
@testable import Macomprendo

/// `ModelManaging` double: reports whatever local URLs the test puts in it.
final class FakeModelManager: ModelManaging, @unchecked Sendable {
    let modelsDirectory: URL

    private let lock = NSLock()
    private var localURLs: [String: URL]
    private(set) var deletedIDs: [String] = []

    init(
        modelsDirectory: URL = URL(fileURLWithPath: "/tmp/macomprendo-fake-models"),
        localURLs: [String: URL] = [:]
    ) {
        self.modelsDirectory = modelsDirectory
        self.localURLs = localURLs
    }

    func setLocalURL(_ url: URL?, for id: String) {
        lock.withLock { localURLs[id] = url }
    }

    func state(of id: String) async -> ModelState {
        guard let url = lock.withLock({ localURLs[id] }) else { return .notDownloaded }
        return .downloaded(url)
    }

    func localURL(for id: String) async -> URL? {
        lock.withLock { localURLs[id] }
    }

    func download(_ id: String) -> AsyncThrowingStream<Double, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(1.0)
            continuation.finish()
        }
    }

    func delete(_ id: String) async throws {
        lock.withLock {
            localURLs[id] = nil
            deletedIDs.append(id)
        }
    }
}
