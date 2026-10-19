import Foundation
@testable import Macomprendo

/// A process list a test sets; counted so a test can prove nothing polled while stopped.
final class FakeAudioProcessMonitor: AudioProcessMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioProcessActivity] = []
    private var reads = 0

    var processes: [AudioProcessActivity] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var snapshotCount: Int { lock.withLock { reads } }

    func snapshot() -> [AudioProcessActivity] {
        lock.withLock {
            reads += 1
            return stored
        }
    }
}
