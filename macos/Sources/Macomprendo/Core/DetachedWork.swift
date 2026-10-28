import Foundation

/// Runs blocking work that cannot be interrupted — a native call with no way to stop it — off the
/// caller's executor, and lets a cancelled caller stop waiting for it. The work itself runs on to
/// the end and its result is dropped; whatever it holds is freed when it returns.
enum DetachedWork {
    static func value<T: Sendable>(priority: TaskPriority = .utility,
                                   _ work: @escaping @Sendable () throws -> T) async throws -> T {
        let outcome = Outcome<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard outcome.wait(with: continuation) else { return }
                Task.detached(priority: priority) {
                    outcome.resume(with: Result { try work() })
                }
            }
        } onCancel: {
            outcome.resume(with: .failure(CancellationError()))
        }
    }

    /// Resumes the caller exactly once — with the work's result or with the cancellation,
    /// whichever comes first — including a cancellation that lands before the caller waits.
    private final class Outcome<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var early: Result<T, Error>?
        private var done = false

        /// `false` when the caller was resumed at once because it was already cancelled.
        func wait(with continuation: CheckedContinuation<T, Error>) -> Bool {
            let early: Result<T, Error>? = lock.withLock {
                if let early = self.early {
                    done = true
                    return early
                }
                self.continuation = continuation
                return nil
            }
            guard let early else { return true }
            continuation.resume(with: early)
            return false
        }

        func resume(with result: Result<T, Error>) {
            let waiting: CheckedContinuation<T, Error>? = lock.withLock {
                guard !done else { return nil }
                guard let continuation else {
                    early = early ?? result
                    return nil
                }
                done = true
                self.continuation = nil
                return continuation
            }
            waiting?.resume(with: result)
        }
    }
}
