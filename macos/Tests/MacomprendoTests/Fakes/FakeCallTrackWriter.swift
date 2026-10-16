import Foundation
@testable import Macomprendo

/// Records what a caller fed one track's writer. The later controller tests assert against it;
/// the writer's own tests use the real `AssetCallTrackWriter`.
final class FakeCallTrackWriter: CallTrackWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(samples: Int, time: TimeInterval)] = []
    private var finishedWriting = false
    private var offset: TimeInterval?
    private var failure: (any Error)?

    /// Chunks handed to `consume`, in order, as sample count and host time.
    var consumed: [(samples: Int, time: TimeInterval)] { lock.withLock { recorded } }
    var finished: Bool { lock.withLock { finishedWriting } }

    var startOffset: TimeInterval? {
        get { lock.withLock { offset } }
        set { lock.withLock { offset = newValue } }
    }

    var finishError: (any Error)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    func consume(_ samples: [Float], at time: TimeInterval) {
        lock.withLock { recorded.append((samples.count, time)) }
    }

    func finish() async throws {
        lock.withLock { finishedWriting = true }
        if let failure { throw failure }
    }
}
