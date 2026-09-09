import Foundation

/// Lets a test hold an async fake at a specific point until it's ready to let it
/// proceed — the async counterpart to a scripted delay, for windows a fixed sleep
/// can't reliably hit (e.g. "cancel while `insert()` is in flight").
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// How many callers are currently suspended in `wait()` — lets a test know a
    /// background task has actually reached the gate before it acts on that timing,
    /// instead of guessing with a fixed sleep.
    var waiterCount: Int { lock.withLock { waiters.count } }
    var opened: Bool { lock.withLock { isOpen } }

    func openOne() {
        let waiter = lock.withLock {
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        waiter?.resume()
    }

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            let pending = waiters
            waiters = []
            return pending
        }
        for continuation in toResume { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeNow: Bool = lock.withLock {
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
