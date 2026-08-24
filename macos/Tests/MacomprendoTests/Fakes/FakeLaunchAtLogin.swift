import Foundation
@testable import Macomprendo

final class FakeLaunchAtLogin: LaunchAtLoginManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled: Bool
    private var _error: (any Error)?
    private var _setCalls: [Bool] = []

    init(enabled: Bool = false) {
        _enabled = enabled
    }

    /// Set to make the next `setEnabled` throw, simulating a user-disabled login item.
    var errorToThrow: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var setCalls: [Bool] { lock.withLock { _setCalls } }

    func isEnabled() -> Bool {
        lock.withLock { _enabled }
    }

    func setEnabled(_ enabled: Bool) throws {
        lock.withLock { _setCalls.append(enabled) }
        if let error = lock.withLock({ _error }) {
            throw error
        }
        lock.withLock { _enabled = enabled }
    }
}
