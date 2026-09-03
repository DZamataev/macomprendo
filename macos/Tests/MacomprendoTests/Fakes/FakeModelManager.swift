import Foundation
@testable import Macomprendo

/// `ModelManaging` double: reports whatever local URLs the test puts in it.
final class FakeModelManager: ModelManaging, @unchecked Sendable {
    let modelsDirectory: URL

    private let lock = NSLock()
    private var localURLs: [String: URL]
    private var engines: [String: LocalEngine] = [:]
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

    func setEngine(_ engine: LocalEngine, for id: String) {
        lock.withLock { engines[id] = engine }
    }

    func state(of id: String) async -> ModelState {
        lock.withLock { localURLs[id] == nil ? .notDownloaded : .downloaded }
    }

    func resolved(_ id: String) async -> ResolvedLocalModel? {
        lock.withLock {
            guard let url = localURLs[id] else { return nil }
            return ResolvedLocalModel(engine: engines[id] ?? .whisperCpp, files: [.ggml: url])
        }
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
