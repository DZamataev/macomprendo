import Foundation
@testable import Macomprendo

/// `EscapeMonitoring` double: records `start()`/`stop()` calls and lets tests fire `onEscape`
/// directly instead of waiting on a real global `NSEvent` monitor.
final class FakeEscapeMonitor: EscapeMonitoring, @unchecked Sendable {
    var onEscape: (@MainActor () -> Void)?

    private let lock = NSLock()
    private var _startCount = 0
    private var _stopCount = 0
    private var _isRunning = false

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var isRunning: Bool { lock.withLock { _isRunning } }

    func start() {
        lock.withLock {
            _startCount += 1
            _isRunning = true
        }
    }

    func stop() {
        lock.withLock {
            _stopCount += 1
            _isRunning = false
        }
    }

    @MainActor
    func fireEscape() {
        onEscape?()
    }
}
