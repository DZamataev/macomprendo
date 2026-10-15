import Foundation
@testable import Macomprendo

/// A scripted call-audio capture. Stands in for the microphone side, and — because the
/// system-audio side is the same `CallAudioCapturing` — for that too.
///
/// `emit` stays lenient: it calls the stored handler even after `stop()`, so a test can prove
/// what a controller does with audio that arrives late, instead of the fake quietly hiding it.
final class ScriptedCallCapture: CallMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CallAudioChunk) -> Void)?
    private var _isRunning = false
    private var _startCount = 0
    private var _stopCount = 0
    private var _startError: Error?
    private var _preferredInputDeviceUIDs: [String?] = []

    var isRunning: Bool { lock.withLock { _isRunning } }
    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }

    /// Every preferred input device handed to the capture, in call order.
    var preferredInputDeviceUIDs: [String?] { lock.withLock { _preferredInputDeviceUIDs } }

    func start(_ handler: @escaping @Sendable (CallAudioChunk) -> Void) throws {
        if let error = startError { throw error }
        // Mirrors `EngineCallMicrophoneCapture.start()`'s double-start guard: a real second
        // `start()` while capturing must not be hidden by a fake that tolerates it.
        try lock.withLock {
            guard !_isRunning else {
                throw MacomprendoError.audio("A call capture is already in progress.")
            }
            _startCount += 1
            _isRunning = true
            self.handler = handler
        }
    }

    func stop() {
        lock.withLock {
            _stopCount += 1
            _isRunning = false
        }
    }

    /// Delivers a chunk, as the capture would from its tap thread.
    func emit(_ chunk: CallAudioChunk) {
        let handler = lock.withLock { self.handler }
        handler?(chunk)
    }

    func setPreferredInputDevice(uid: String?) {
        lock.withLock { _preferredInputDeviceUIDs.append(uid) }
    }
}
