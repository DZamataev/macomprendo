import Foundation
@testable import Macomprendo

final class StubPuller: ModelPulling, @unchecked Sendable {
    private let lock = NSLock()
    private var _progress: [PullProgress] = []
    private var _error: Error?
    private var _pulled: [String] = []

    var progress: [PullProgress] {
        get { lock.withLock { _progress } }
        set { lock.withLock { _progress = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var pulled: [String] { lock.withLock { _pulled } }

    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        lock.withLock { _pulled.append(model) }
        let progress = self.progress
        let error = self.error
        return AsyncThrowingStream { continuation in
            for step in progress { continuation.yield(step) }
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
    }
}
