import Foundation
import Testing
@testable import Macomprendo

/// A scripted call-audio capture. Stands in for the microphone side, and — because the
/// system-audio side is the same `CallAudioCapturing` — for that too.
///
/// `emit` stays lenient: it calls the stored handler even after `stop()`, so a test can prove
/// what a controller does with audio that arrives late, instead of the fake quietly hiding it.
///
/// It also enforces the handler contract `EngineCallMicrophoneCapture` cannot survive: a
/// delivery is marked in flight around the handler call, and `start(_:)`, `stop()` or
/// `setPreferredInputDevice(uid:)` arriving during one records a test issue instead of hanging
/// on the real capture's non-recursive state lock (which is held across the handler call).
final class ScriptedCallCapture: CallMicrophoneCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (CallAudioChunk) -> Void)?
    private var _isRunning = false
    private var _startCount = 0
    private var _stopCount = 0
    private var _startError: Error?
    private var _preferredInputDeviceUIDs: [String?] = []
    /// Set around `emit`'s handler call. Not thread-scoped, so a `stop()` racing a delivery
    /// from another thread also reports — acceptable for a fake driven from a test's thread.
    private var isDelivering = false

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
        reportReentry()
    }

    func stop() {
        lock.withLock {
            _stopCount += 1
            _isRunning = false
        }
        reportReentry()
    }

    /// Delivers a chunk, as the capture would from its tap thread.
    func emit(_ chunk: CallAudioChunk) {
        guard let delivery = lock.withLock({ handler }) else { return }
        lock.withLock { isDelivering = true }
        delivery(chunk)
        lock.withLock { isDelivering = false }
    }

    func setPreferredInputDevice(uid: String?) {
        lock.withLock { _preferredInputDeviceUIDs.append(uid) }
        reportReentry()
    }

    private var _releasesInputWhenStopped: [Bool] = []
    /// Every release choice handed to the capture, in call order.
    var releasesInputWhenStopped: [Bool] { lock.withLock { _releasesInputWhenStopped } }

    func setReleasesInputWhenStopped(_ releases: Bool) {
        lock.withLock { _releasesInputWhenStopped.append(releases) }
    }

    private var _holdsInput = false
    private var _releaseInputCount = 0
    var holdsInput: Bool {
        get { lock.withLock { _holdsInput } }
        set { lock.withLock { _holdsInput = newValue } }
    }
    var releaseInputCount: Int { lock.withLock { _releaseInputCount } }

    func releaseInput() {
        lock.withLock {
            _holdsInput = false
            _releaseInputCount += 1
        }
    }

    /// A synchronous callback from inside the handler is the deadlock the real capture hits;
    /// reporting it keeps a controller that would hang from passing here.
    private func reportReentry() {
        guard lock.withLock({ isDelivering }) else { return }
        Issue.record("handler re-entered the capture synchronously")
    }
}
