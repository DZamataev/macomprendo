import Foundation

/// Records the durations a unit under test would have slept for, and returns instantly.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [TimeInterval] = []

    var durations: [TimeInterval] { lock.withLock { _durations } }

    func record(_ duration: TimeInterval) {
        lock.withLock { _durations.append(duration) }
    }
}

/// Counts calls; `increment()` returns the new value.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var count: Int { lock.withLock { value } }
}
