import Foundation
@testable import Macomprendo

final class ScriptedRecorder: AudioRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var starts = 0
    private var stops = 0

    var samples: [Float] = [0.1, -0.1, 0.2]
    var startError: MacomprendoError?

    let level: AsyncStream<Float> = AsyncStream { $0.finish() }
    // Ruling 1 (task-9 pre-flight): `AudioRecording` gained `autoStopped` after this
    // brief was written. It never fires in these tests.
    let autoStopped: AsyncStream<Void> = AsyncStream { _ in }

    private(set) var maximumDurations: [TimeInterval] = []

    func setMaximumDuration(_ seconds: TimeInterval) {
        lock.withLock { maximumDurations.append(seconds) }
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func start() async throws {
        if let startError { throw startError }
        lock.withLock { recording = true; starts += 1 }
    }

    func stop() async -> [Float] {
        lock.withLock { recording = false; stops += 1 }
        return samples
    }

    var isRecording: Bool { get async { lock.withLock { recording } } }
}
