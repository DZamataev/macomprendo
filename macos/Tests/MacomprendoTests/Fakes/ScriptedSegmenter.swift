import Foundation
@testable import Macomprendo

/// A segmenter whose sessions return a fixed script: one batch of segments per `accept` call
/// (empty once the script runs out) and one batch from `finish()`.
final class ScriptedSegmenter: SpeechSegmenting, @unchecked Sendable {
    private let lock = NSLock()
    private var _acceptScript: [[SpeechSegment]]
    private var _finishSegments: [SpeechSegment]
    private var _sessionJoinGaps: [TimeInterval] = []

    init(acceptScript: [[SpeechSegment]] = [], finishSegments: [SpeechSegment] = []) {
        _acceptScript = acceptScript
        _finishSegments = finishSegments
    }

    /// Returned by successive `accept` calls, one batch each; once exhausted, `accept` returns [].
    var acceptScript: [[SpeechSegment]] {
        get { lock.withLock { _acceptScript } }
        set { lock.withLock { _acceptScript = newValue } }
    }

    /// Returned by `finish()`, every time.
    var finishSegments: [SpeechSegment] {
        get { lock.withLock { _finishSegments } }
        set { lock.withLock { _finishSegments = newValue } }
    }

    /// The `joinGap` each session was made with, in order.
    var sessionJoinGaps: [TimeInterval] { lock.withLock { _sessionJoinGaps } }

    func makeSession(joinGap: TimeInterval) throws -> any SpeechSegmentingSession {
        lock.withLock {
            _sessionJoinGaps.append(joinGap)
            return ScriptedSegmenterSession(acceptScript: _acceptScript, finishSegments: _finishSegments)
        }
    }
}

/// One `ScriptedSegmenter` run: walks the accept script once, then returns nothing.
private final class ScriptedSegmenterSession: SpeechSegmentingSession {
    private let acceptScript: [[SpeechSegment]]
    private let finishSegments: [SpeechSegment]
    private var index = 0

    init(acceptScript: [[SpeechSegment]], finishSegments: [SpeechSegment]) {
        self.acceptScript = acceptScript
        self.finishSegments = finishSegments
    }

    func accept(_ samples: [Float]) -> [SpeechSegment] {
        guard index < acceptScript.count else { return [] }
        defer { index += 1 }
        return acceptScript[index]
    }

    func finish() -> [SpeechSegment] { finishSegments }
}
