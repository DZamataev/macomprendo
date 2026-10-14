import Foundation
import Testing
@testable import Macomprendo

/// The pure span rules: regions closer than `joinGap` join with the audio between them, spans are
/// padded, non-speech over `joinGap` is dropped, spans are cut to `maximumDuration` at a quiet
/// frame, and the buffer stays bounded while speech streams in.
@Suite struct SpeechSpanAssemblerTests {
    private let rate = 16_000

    private func loud(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * 16_000)).map { $0 % 2 == 0 ? 0.5 : -0.5 }
    }

    private func quiet(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    private func region(_ start: Double, _ end: Double) -> SpeechSpanAssembler.Region {
        SpeechSpanAssembler.Region(startSample: Int(start * 16_000), endSample: Int(end * 16_000))
    }

    @Test func aCompletedRegionBecomesOnePaddedSegment() throws {
        let assembler = SpeechSpanAssembler(sampleRate: rate)
        let stream = quiet(1) + loud(1) + quiet(1)

        let flushed = assembler.accept(samples: stream, regions: [region(1, 2)],
                                       speechInProgress: false)
        #expect(flushed.isEmpty)

        let segments = assembler.finish()
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(abs(segment.start - 0.7) < 1e-9)                     // 1 s − 0.3 s padding
        #expect(segment.samples.count == Int(1.6 * 16_000))          // 1 s + 0.3 s on each side
        #expect(segment.sampleRate == rate)
    }

    @Test func regionsThreeSecondsApartJoinAndKeepTheGapAudio() throws {
        let assembler = SpeechSpanAssembler(sampleRate: rate)
        // 0–0.5 quiet, 0.5–1.5 speech, 1.5–3.5 quiet, 3.5–4.5 speech, 4.5–5 quiet.
        let stream = quiet(0.5) + loud(1) + quiet(2) + loud(1) + quiet(0.5)

        let flushed = assembler.accept(samples: stream,
                                       regions: [region(0.5, 1.5), region(3.5, 4.5)],
                                       speechInProgress: false)
        let segments = flushed + assembler.finish()

        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(abs(segment.start - 0.2) < 1e-9)
        // 4.6 s: both regions and the 2 s of audio between them, padded once on each side.
        #expect(segment.samples.count == Int(4.6 * 16_000))
    }

    @Test func regionsTwelveSecondsApartBecomeTwoSegmentsAndTheGapIsDropped() throws {
        let assembler = SpeechSpanAssembler(sampleRate: rate)
        let stream = quiet(1) + loud(1) + quiet(12) + loud(1) + quiet(1)

        let flushed = assembler.accept(samples: stream,
                                       regions: [region(1, 2), region(14, 15)],
                                       speechInProgress: false)
        let segments = flushed + assembler.finish()

        #expect(segments.count == 2)
        let first = try #require(segments.first)
        let second = try #require(segments.last)
        #expect(abs(first.start - 0.7) < 1e-9)
        #expect(first.samples.count == Int(1.6 * 16_000))
        // No padding on the far side of the dropped gap: each span keeps its own 0.3 s.
        #expect(abs(second.start - 13.7) < 1e-9)
        #expect(second.samples.count == Int(1.6 * 16_000))
    }

    @Test func paddingClampsAtTheStreamStartAndEnd() throws {
        let atStart = SpeechSpanAssembler(sampleRate: rate)
        let first = atStart.accept(samples: loud(1) + quiet(4), regions: [region(0, 1)],
                                   speechInProgress: false) + atStart.finish()
        #expect(first.count == 1)
        let firstSegment = try #require(first.first)
        #expect(firstSegment.start == 0)                              // no room to pad before 0
        #expect(abs(firstSegment.end - 1.3) < 1e-9)

        let atEnd = SpeechSpanAssembler(sampleRate: rate)
        let last = atEnd.accept(samples: quiet(4) + loud(1), regions: [region(4, 5)],
                                speechInProgress: false) + atEnd.finish()
        #expect(last.count == 1)
        let lastSegment = try #require(last.first)
        #expect(abs(lastSegment.start - 3.7) < 1e-9)
        #expect(abs(lastSegment.end - 5) < 1e-9)                      // clamped at the stream end
    }

    @Test func aSpanClosesWhenTheStreamAdvancesPastItsEndWithoutANewRegion() throws {
        let assembler = SpeechSpanAssembler(sampleRate: rate)

        let opened = assembler.accept(samples: quiet(2), regions: [region(1, 2)],
                                      speechInProgress: false)
        #expect(opened.isEmpty)                                       // 2 s in, 10 s not reached

        // The stream reaches 13 s: more than joinGap past the span's end at 2 s.
        let flushed = assembler.accept(samples: quiet(11), regions: [], speechInProgress: false)

        #expect(flushed.count == 1)                                   // emitted from accept, not finish
        let segment = try #require(flushed.first)
        #expect(abs(segment.start - 0.7) < 1e-9)
        #expect(segment.samples.count == Int(1.6 * 16_000))
    }

    @Test func aLongerSpanIsCutAtAQuietFrameBeforeTheCap() throws {
        let assembler = SpeechSpanAssembler(sampleRate: rate)
        // 95 s of speech with a 0.1 s dip at 28.5 s — inside the first cut's 5 s search window.
        let stream = loud(28.5) + quiet(0.1) + loud(95 - 28.6)

        var emitted: [SpeechSegment] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 16_000, stream.count)
            emitted += assembler.accept(samples: Array(stream[offset..<end]), regions: [],
                                        speechInProgress: true)
            offset = end
        }
        emitted += assembler.accept(samples: [], regions: [region(0, 95)], speechInProgress: true)
        emitted += assembler.finish()

        #expect(emitted.count == 4)
        #expect(emitted.allSatisfy { $0.duration <= SpeechSegmentSplitter.maximumDuration })
        for (previous, next) in zip(emitted, emitted.dropFirst()) {
            #expect(abs(previous.end - next.start) < 1e-9)
        }
        #expect(emitted.map(\.samples.count).reduce(0, +) == 95 * 16_000)
        // The first cut lands in the dip, not at the cap.
        let firstPiece = try #require(emitted.first)
        #expect(firstPiece.duration > 28.5)
        #expect(firstPiece.duration < 28.7)
    }

    /// The buffer must stay bounded however long the speech runs: the open span is cut down to a
    /// remainder as regions arrive, so retention is at most the open span's remainder (under one
    /// `maximumDuration`), plus the join gap and the one region the detector is still reporting.
    /// With 20 s regions 1 s apart that is about 50 s; 51.5 s is the stated bound with headroom.
    @Test func continuousSpeechNeverRetainsMoreThanTheStatedBound() {
        let assembler = SpeechSpanAssembler(sampleRate: rate)
        var regions: [(start: Double, end: Double)] = []
        for index in 0..<28 {                                        // [0,20], [21,41], … [567,587]
            regions.append((Double(index * 21), Double(index * 21 + 20)))
        }

        var emittedBeforeFinish = 0
        var maxRetained = 0
        var nextRegion = 0
        for second in 0..<600 {                                      // 10 minutes in 1 s chunks
            let t = Double(second)
            let inSpeech = regions.contains { $0.start <= t && t < $0.end + 0.5 }
            var due: [SpeechSpanAssembler.Region] = []
            while nextRegion < regions.count, regions[nextRegion].end + 0.5 <= t + 1 {
                due.append(region(regions[nextRegion].start, regions[nextRegion].end))
                nextRegion += 1
            }
            let flushed = assembler.accept(samples: loud(1), regions: due,
                                           speechInProgress: inSpeech)
            emittedBeforeFinish += flushed.count
            maxRetained = max(maxRetained, assembler.retainedSampleCount)
        }

        #expect(emittedBeforeFinish > 0, "pieces must be emitted while the stream is still running")
        // The upper bound is only meaningful if the workload really did fill the buffer.
        #expect(maxRetained > Int(40 * 16_000), "retained \(maxRetained) samples — buffer never grew")
        #expect(maxRetained <= Int(51.5 * 16_000), "retained \(maxRetained) samples")
    }
}
