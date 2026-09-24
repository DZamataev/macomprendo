import Foundation
import Testing

/// A sleep that returns only when the test releases it, one call at a time. Records every
/// duration it was asked for, so a test can assert both *how long* code meant to wait and
/// *what* it did once the wait ended — without sleeping for real.
final class GatedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [TimeInterval] = []
    private var gates: [AsyncGate] = []

    /// Every duration passed to `sleep`, in call order.
    var requests: [TimeInterval] { lock.withLock { _requests } }

    func sleep(_ seconds: TimeInterval) async {
        // Never times out on its own: a sleep a test leaves pending is a sleep that never
        // ended, which is exactly what the test means by leaving it.
        let gate = AsyncGate(timeout: .seconds(3600), onTimeout: {})
        lock.withLock {
            _requests.append(seconds)
            gates.append(gate)
        }
        await gate.wait()
    }

    /// Ends the `index`th sleep (zero-based, in call order). Releasing a sleep nobody asked
    /// for is a failed expectation, not a crash that takes the whole suite down with it.
    func release(_ index: Int) {
        let gate = lock.withLock { gates.indices.contains(index) ? gates[index] : nil }
        guard let gate else {
            Issue.record("No sleep #\(index) was requested; \(requests.count) were.")
            return
        }
        gate.open()
    }
}
