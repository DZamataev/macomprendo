import Foundation
@testable import Macomprendo

final class FakeAudioRecorder: AudioRecording, @unchecked Sendable {
    let level: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    private let lock = NSLock()
    private var _recording = false
    private var _startCount = 0
    private var _stopCount = 0
    private var _samplesToReturn: [Float] = [0.1, 0.2]
    private var _startError: Error?

    init() {
        var continuation: AsyncStream<Float>.Continuation!
        level = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        levelContinuation = continuation
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

    func start() async throws {
        if let error = startError { throw error }
        lock.withLock {
            _startCount += 1
            _recording = true
        }
    }

    func stop() async -> [Float] {
        lock.withLock {
            _stopCount += 1
            _recording = false
            return _samplesToReturn
        }
    }

    func emitLevel(_ value: Float) {
        levelContinuation.yield(value)
    }
}
