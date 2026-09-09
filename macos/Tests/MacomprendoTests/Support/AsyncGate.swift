import Foundation
import Testing

/// Lets a test hold an async fake at a specific point until it's ready to let it
/// proceed — the async counterpart to a scripted delay, for windows a fixed sleep
/// can't reliably hit (e.g. "cancel while `insert()` is in flight").
final class AsyncGate: @unchecked Sendable {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private let timeout: Duration
    private let onTimeout: @Sendable () -> Void
    private var isOpen = false
    private var waiters: [Waiter] = []

    init(timeout: Duration = .seconds(2),
         onTimeout: @escaping @Sendable () -> Void = {
             Issue.record("AsyncGate timed out waiting for open()")
         }) {
        self.timeout = timeout
        self.onTimeout = onTimeout
    }

    /// How many callers are currently suspended in `wait()` — lets a test know a
    /// background task has actually reached the gate before it acts on that timing,
    /// instead of guessing with a fixed sleep.
    var waiterCount: Int { lock.withLock { waiters.count } }
    var opened: Bool { lock.withLock { isOpen } }

    func openOne() {
        let waiter = lock.withLock {
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        waiter?.continuation.resume()
    }

    func open() {
        let toResume: [Waiter] = lock.withLock {
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        for waiter in toResume { waiter.continuation.resume() }
    }

    func wait() async {
        let id = UUID()
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(Waiter(id: id, continuation: continuation))
                return false
            }
            if resumeNow {
                continuation.resume()
            } else {
                Task { [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: timeout)
                    timeoutWaiter(id)
                }
            }
        }
    }

    private func timeoutWaiter(_ id: UUID) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
            return waiters.remove(at: index).continuation
        }
        guard let continuation else { return }
        onTimeout()
        continuation.resume()
    }
}
