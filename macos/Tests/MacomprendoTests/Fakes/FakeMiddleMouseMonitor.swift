import Foundation
@testable import Macomprendo

final class FakeMiddleMouseMonitor: MiddleMouseMonitoring, @unchecked Sendable {
    let events: AsyncStream<MiddleMouseEvent>
    private let continuation: AsyncStream<MiddleMouseEvent>.Continuation
    private let lock = NSLock()
    private var _isEnabled = false

    init() {
        var streamContinuation: AsyncStream<MiddleMouseEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { streamContinuation = $0 }
        continuation = streamContinuation
    }

    var isEnabled: Bool { lock.withLock { _isEnabled } }

    func send(_ event: MiddleMouseEvent) {
        continuation.yield(event)
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { _isEnabled = enabled }
    }
}
