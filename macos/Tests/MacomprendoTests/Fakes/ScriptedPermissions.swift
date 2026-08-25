import Foundation
@testable import Macomprendo

final class ScriptedPermissions: PermissionsChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _current: PermissionStatus
    private var _afterRequest: PermissionStatus
    private var _statusGate: AsyncGate?

    init(current: PermissionStatus = .granted, afterRequest: PermissionStatus = .granted) {
        self._current = current
        self._afterRequest = afterRequest
    }

    var current: PermissionStatus {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    var afterRequest: PermissionStatus {
        get { lock.withLock { _afterRequest } }
        set { lock.withLock { _afterRequest = newValue } }
    }

    /// Blocks `status(of:)` until the test opens it — lets a test suspend `startRecording()`
    /// mid-permission-check to exercise a race against `cancel()`.
    var statusGate: AsyncGate? {
        get { lock.withLock { _statusGate } }
        set { lock.withLock { _statusGate = newValue } }
    }

    func status(of kind: PermissionKind) async -> PermissionStatus {
        if let statusGate { await statusGate.wait() }
        return current
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus { afterRequest }
    func openSystemSettings(for kind: PermissionKind) {}
}
