import Foundation
@testable import Macomprendo

/// A diarizer that returns scripted turns (or a scripted error), optionally held at a gate so a
/// test can cancel the job mid-diarization. Records the length of every audio it was given.
final class ScriptedDiarizer: SpeakerDiarizing, @unchecked Sendable {
    private let lock = NSLock()
    private var _ready: Bool
    private var _turns: [SpeakerTurn]
    private var _failure: Error?
    private var _gate: AsyncGate?
    private var _sampleCounts: [Int] = []

    init(ready: Bool = true, turns: [SpeakerTurn] = [], failure: Error? = nil,
         gate: AsyncGate? = nil) {
        _ready = ready
        _turns = turns
        _failure = failure
        _gate = gate
    }

    var ready: Bool {
        get { lock.withLock { _ready } }
        set { lock.withLock { _ready = newValue } }
    }

    /// How many samples each `diarize` call received, in order.
    var sampleCounts: [Int] { lock.withLock { _sampleCounts } }

    func isReady() async -> Bool { ready }

    func diarize(_ samples: [Float], sampleRate: Int) async throws -> [SpeakerTurn] {
        let (turns, failure, gate) = lock.withLock {
            _sampleCounts.append(samples.count)
            return (_turns, _failure, _gate)
        }
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if let failure { throw failure }
        return turns
    }
}
