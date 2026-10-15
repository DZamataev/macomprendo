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

    @Test func aSpanUpTo35SecondsIsNotSplit() {
        // 32.6 s, the interview's tail span: cut at the old 30 s cap it left a 2.9 s remainder
        // of padding, outro music and a 0.84 s VAD blip, and whisper large-v3-turbo wrote
        // "Субтитры сделал DimaTorzok" for it. A span is now split only above 35 s.
        let segment = SpeechSegment(start: 12, samples: loud(32.6), sampleRate: rate)
        #expect(SpeechSegmentSplitter.split(segment) == [segment])
    }

    @Test func aSplitNeverLeavesARemainderUnderFiveSeconds() {
        for seconds in [36.0, 61.0] {
            let samples = loud(seconds)
            let pieces = SpeechSegmentSplitter.split(
                SpeechSegment(start: 0, samples: samples, sampleRate: rate))
            #expect(pieces.allSatisfy { $0.duration >= SpeechSegmentSplitter.minimumRemainder },
                    "pieces: \(pieces.map(\.duration))")
            #expect(pieces.allSatisfy {
                $0.duration <= SpeechSegmentSplitter.maximumDuration
                    + SpeechSegmentSplitter.minimumRemainder
            }, "pieces: \(pieces.map(\.duration))")
            #expect(pieces.map(\.samples.count).reduce(0, +) == samples.count)
            for (previous, next) in zip(pieces, pieces.dropFirst()) {
                #expect(abs(previous.end - next.start) < 1e-9)
            }
        }
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

    @Test func everyPieceFitsTheSplitRuleWhateverTheInput() {
        let pieces = SpeechSegmentSplitter.split(
            SpeechSegment(start: 0, samples: loud(95), sampleRate: rate))
        #expect(pieces.count == 4)
        #expect(pieces.allSatisfy {
            $0.duration <= SpeechSegmentSplitter.maximumDuration
                + SpeechSegmentSplitter.minimumRemainder
        })
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
