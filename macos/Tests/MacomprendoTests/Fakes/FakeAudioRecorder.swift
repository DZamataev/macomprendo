import Foundation
@testable import Macomprendo

final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    final class StopControl: @unchecked Sendable {
        let invoked = AsyncGate()
        let allowCompletion = AsyncGate()
        let completed = AsyncGate()
    }

    let level: AsyncStream<Float>
    let autoStopped: AsyncStream<Void>
    private let levelContinuation: AsyncStream<Float>.Continuation
    private let autoStopContinuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var _recording = false
    private var _startCount = 0
    private var _stopCount = 0
    private var _samplesToReturn: [Float] = [0.1, 0.2]
    private var _startError: Error?
    private var _stopGate: AsyncGate?
    private var _stopControls: [StopControl] = []

    init() {
        var continuation: AsyncStream<Float>.Continuation!
        level = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        levelContinuation = continuation
        var autoStopContinuation: AsyncStream<Void>.Continuation!
        autoStopped = AsyncStream(bufferingPolicy: .unbounded) { autoStopContinuation = $0 }
        self.autoStopContinuation = autoStopContinuation
    }

    var samplesToReturn: [Float] {
        get { lock.withLock { _samplesToReturn } }
        set { lock.withLock { _samplesToReturn = newValue } }
    }

    var startError: Error? {
        get { lock.withLock { _startError } }
        set { lock.withLock { _startError = newValue } }
    }

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var isRecording: Bool { lock.withLock { _recording } }

    /// Blocks `stop()` until the test opens it — for asserting a fast restart waits
    /// for a still-pending stop from a cancel().
    var stopGate: AsyncGate? {
        get { lock.withLock { _stopGate } }
        set { lock.withLock { _stopGate = newValue } }
    }

    /// Scripts independently controlled stop calls and exposes acknowledged invocation and
    /// completion points for overlapping-stop ordering tests.
    func enqueueStopControl(_ control: StopControl) {
        lock.withLock { _stopControls.append(control) }
    }

    func start() async throws {
        if let error = startError { throw error }
        // Mirrors `AVAudioEngineRecorder.start()`'s double-start guard (AudioRecorder.swift):
        // a real second `start()` while recording traps/fails, so a controller-level race
        // that lets two `start()`s reach the recorder must be caught by a test, not hidden
        // by a fake that tolerates it.
        try lock.withLock {
            guard !_recording else {
                throw MacomprendoError.audio("Recording is already in progress.")
            }
            _startCount += 1
            _recording = true
        }
    }

    func stop() async -> [Float] {
        let control = lock.withLock {
            _stopControls.isEmpty ? nil : _stopControls.removeFirst()
        }
        control?.invoked.open()
        if let control {
            await control.allowCompletion.wait()
        } else if let stopGate {
            await stopGate.wait()
        }
        let samples = lock.withLock {
            _stopCount += 1
            _recording = false
            return _samplesToReturn
        }
        control?.completed.open()
        return samples
    }

    func emitLevel(_ value: Float) {
        levelContinuation.yield(value)
    }

    /// Signals an auto-stop, as `AVAudioEngineRecorder` does when it auto-stops after
    /// hitting `maxDuration` — without ever finishing the shared `level` stream, which
    /// must keep working for every recording after this one.
    func triggerAutoStop() {
        autoStopContinuation.yield(())
    }
}
