import Foundation
import Testing
@testable import Macomprendo

@Suite struct SpeechSegmentSplitterTests {
    private let rate = 16_000

    private func loud(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { index in index % 2 == 0 ? 0.5 : -0.5 }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        Array(repeating: 0, count: Int(seconds * Double(rate)))
    }

    @Test func aSegmentWithinTheCapPassesThroughUnchanged() {
        let segment = SpeechSegment(start: 12, samples: loud(29.5), sampleRate: rate)
        #expect(SpeechSegmentSplitter.split(segment) == [segment])
    }

    @Test func aSegmentShorterThanTheMinimumIsDropped() {
        let segment = SpeechSegment(start: 0, samples: loud(0.29), sampleRate: rate)
        #expect(SpeechSegmentSplitter.split(segment).isEmpty)
    }

    @Test func aLongSegmentSplitsAtTheQuietestPointOfTheLastFiveSeconds() throws {
        // 27 s of speech, 0.2 s of silence, 10 s of speech: the cut belongs in the silence.
        let samples = loud(27) + quiet(0.2) + loud(10)
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 100, samples: samples, sampleRate: rate))
        #expect(pieces.count == 2)
        let first = try #require(pieces.first)
        #expect(first.start == 100)
        #expect(first.duration > 27 && first.duration < 27.2)
        #expect(pieces[1].start == first.end)
        #expect(pieces.map(\.samples.count).reduce(0, +) == samples.count)
    }

    @Test func everyPieceFitsTheCapWhateverTheInput() {
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 0, samples: loud(95), sampleRate: rate))
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy { $0.duration <= SpeechSegmentSplitter.maximumDuration })
        #expect(pieces.map(\.samples.count).reduce(0, +) == 95 * rate)
    }

    @Test func piecesAreContiguousAndOrdered() {
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 3, samples: loud(70), sampleRate: rate))
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            #expect(abs(previous.end - next.start) < 1e-9)
        }
    }
}
