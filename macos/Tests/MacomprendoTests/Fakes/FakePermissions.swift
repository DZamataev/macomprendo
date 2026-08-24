import Foundation
@testable import Macomprendo

final class FakePermissions: PermissionsChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _statuses: [PermissionKind: PermissionStatus] = [:]
    private var _requestResults: [PermissionKind: PermissionStatus] = [:]
    private var _openedPanes: [PermissionKind] = []
    private var _requested: [PermissionKind] = []
    private var _statusGate: AsyncGate?

    var statuses: [PermissionKind: PermissionStatus] {
        get { lock.withLock { _statuses } }
        set { lock.withLock { _statuses = newValue } }
    }

    var requestResults: [PermissionKind: PermissionStatus] {
        get { lock.withLock { _requestResults } }
        set { lock.withLock { _requestResults = newValue } }
    }

    var openedPanes: [PermissionKind] { lock.withLock { _openedPanes } }
    var requested: [PermissionKind] { lock.withLock { _requested } }

    /// Blocks `status(of:)` until the test opens it — lets a test suspend a controller
    /// mid-permission-check to exercise a race against a second concurrent call.
    var statusGate: AsyncGate? {
        get { lock.withLock { _statusGate } }
        set { lock.withLock { _statusGate = newValue } }
    }

    func status(of kind: PermissionKind) async -> PermissionStatus {
        if let statusGate { await statusGate.wait() }
        return lock.withLock { _statuses[kind] ?? .granted }
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        lock.withLock {
            _requested.append(kind)
            let result = _requestResults[kind] ?? _statuses[kind] ?? .granted
            _statuses[kind] = result
            return result
        }
    }

    func openSystemSettings(for kind: PermissionKind) {
        lock.withLock { _openedPanes.append(kind) }
    }
}
