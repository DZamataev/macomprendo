import Foundation
@testable import Macomprendo

final class FakeOllamaDetector: OllamaDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _isRunningResult = false
    private var _probed: [URL] = []

    var isRunningResult: Bool {
        get { lock.withLock { _isRunningResult } }
        set { lock.withLock { _isRunningResult = newValue } }
    }

    var probed: [URL] { lock.withLock { _probed } }

    func isRunning(at url: URL) async -> Bool {
        lock.withLock {
            _probed.append(url)
            return _isRunningResult
        }
    }
}
