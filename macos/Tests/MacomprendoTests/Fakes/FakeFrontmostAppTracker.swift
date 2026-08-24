import Foundation
@testable import Macomprendo

final class FakeFrontmostAppTracker: FrontmostAppTracking, @unchecked Sendable {
    private let lock = NSLock()
    private var _appToCapture: FrontmostApp? = FrontmostApp(pid: 1, bundleID: "com.apple.TextEdit", name: "TextEdit")
    private var _activateResult = true
    private var _activated: [FrontmostApp] = []

    var appToCapture: FrontmostApp? {
        get { lock.withLock { _appToCapture } }
        set { lock.withLock { _appToCapture = newValue } }
    }

    var activateResult: Bool {
        get { lock.withLock { _activateResult } }
        set { lock.withLock { _activateResult = newValue } }
    }

    var activated: [FrontmostApp] { lock.withLock { _activated } }

    func capture() -> FrontmostApp? { lock.withLock { _appToCapture } }

    func activate(_ app: FrontmostApp) async -> Bool {
        lock.withLock {
            _activated.append(app)
            return _activateResult
        }
    }
}
