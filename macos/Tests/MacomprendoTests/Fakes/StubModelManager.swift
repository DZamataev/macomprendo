import Foundation
@testable import Macomprendo

/// Scriptable `ModelManaging` for view-model tests.
/// (Plan 2 ships `FakeModelManager`; this stub exists because the view-model tests below need to
/// script per-id states, progress fractions and failures. Use `FakeModelManager` instead only if it
/// already exposes `states`, `downloadFractions`, `downloadError` and `deleted`.)
final class StubModelManager: ModelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _states: [String: ModelState] = [:]
    private var _downloadFractions: [Double] = [0.25, 1.0]
    private var _downloadError: Error?
    private var _deleted: [String] = []
    private var _resolvedFiles: [String: [ModelFileRole: URL]] = [:]
    private var _resolvedEngines: [String: LocalEngine] = [:]

    let modelsDirectory = URL(fileURLWithPath: "/tmp/macomprendo-tests/models", isDirectory: true)

    var states: [String: ModelState] {
        get { lock.withLock { _states } }
        set { lock.withLock { _states = newValue } }
    }

    var downloadFractions: [Double] {
        get { lock.withLock { _downloadFractions } }
        set { lock.withLock { _downloadFractions = newValue } }
    }

    var downloadError: Error? {
        get { lock.withLock { _downloadError } }
        set { lock.withLock { _downloadError = newValue } }
    }

    var resolvedFiles: [String: [ModelFileRole: URL]] {
        get { lock.withLock { _resolvedFiles } }
        set { lock.withLock { _resolvedFiles = newValue } }
    }

    var resolvedEngines: [String: LocalEngine] {
        get { lock.withLock { _resolvedEngines } }
        set { lock.withLock { _resolvedEngines = newValue } }
    }

    var deleted: [String] { lock.withLock { _deleted } }

    func state(of id: String) async -> ModelState {
        lock.withLock { _states[id] ?? .notDownloaded }
    }

    func resolved(_ id: String) async -> ResolvedLocalModel? {
        lock.withLock {
            guard let files = _resolvedFiles[id] else { return nil }
            return ResolvedLocalModel(engine: _resolvedEngines[id] ?? .whisperCpp, files: files)
        }
    }

    func download(_ id: String) -> AsyncThrowingStream<Double, Error> {
        let fractions = downloadFractions
        let error = downloadError
        return AsyncThrowingStream { continuation in
            Task { [weak self] in
                for fraction in fractions { continuation.yield(fraction) }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    self?.states[id] = .downloaded
                    continuation.finish()
                }
            }
        }
    }

    func delete(_ id: String) async throws {
        lock.withLock {
            _deleted.append(id)
            _states[id] = .notDownloaded
        }
    }
}
