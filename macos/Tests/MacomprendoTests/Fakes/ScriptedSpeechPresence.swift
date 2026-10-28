import Foundation
@testable import Macomprendo

/// A speech-share measurer that returns scripted fractions in order (the last one repeats) and
/// counts how often it was asked — the gate must not measure segments it can decide without.
final class ScriptedSpeechPresence: SpeechPresenceMeasuring, @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private var _measured = 0

    init(_ fractions: [Double]) { self.fractions = fractions }

    var measured: Int { lock.withLock { _measured } }

    func speechFraction(of samples: [Float], sampleRate: Int) throws -> Double {
        lock.withLock {
            _measured += 1
            return fractions.count > 1 ? fractions.removeFirst() : (fractions.first ?? 0)
        }
    }
}
