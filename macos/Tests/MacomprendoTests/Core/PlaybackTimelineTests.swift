import Foundation
import Testing
@testable import Macomprendo

struct PlaybackTimelineTests {
    private func seg(_ start: TimeInterval, _ end: TimeInterval,
                     _ speaker: TranscriptSpeaker? = nil) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: "t", speaker: speaker)
    }

    @Test func nothingIsActiveBeforeTheFirstSegment() {
        let timeline = PlaybackTimeline(segments: [seg(2, 4), seg(5, 7)])
        #expect(timeline.activeIndex(at: 0) == nil)
        #expect(timeline.activeIndex(at: 1.99) == nil)
    }

    @Test func aPositionInsideASegmentMarksIt() {
        let timeline = PlaybackTimeline(segments: [seg(0, 2), seg(3, 5), seg(10, 12)])
        #expect(timeline.activeIndex(at: 0) == 0)
        #expect(timeline.activeIndex(at: 3) == 1)
        #expect(timeline.activeIndex(at: 11) == 2)
    }

    @Test func theMarkerOutlivesASegmentByTheGraceThenGoes() {
        let timeline = PlaybackTimeline(segments: [seg(0, 2), seg(10, 12)])
        #expect(timeline.activeIndex(at: 2.9) == 0)
        #expect(timeline.activeIndex(at: 3.0) == 0)
        #expect(timeline.activeIndex(at: 3.01) == nil)
        #expect(timeline.activeIndex(at: 9.99) == nil)
    }

    @Test func overlappingSpeakersMarkTheLaterStart() {
        let timeline = PlaybackTimeline(segments: [seg(0, 30, .me), seg(5, 7, .others)])
        #expect(timeline.activeIndex(at: 4) == 0)
        #expect(timeline.activeIndex(at: 6) == 1)
        // The short reply is over (past its grace): back to the long one still running.
        #expect(timeline.activeIndex(at: 9) == 0)
    }

    @Test func theLastSegmentAndPastIt() {
        let timeline = PlaybackTimeline(segments: [seg(0, 2), seg(3, 5)])
        #expect(timeline.activeIndex(at: 5.5) == 1)
        #expect(timeline.activeIndex(at: 60) == nil)
    }

    @Test func anEmptyTranscriptMarksNothing() {
        #expect(PlaybackTimeline(segments: []).activeIndex(at: 3) == nil)
    }

    @Test func theLookbackBoundsTheSearch() {
        // A segment longer than the lookback is not found from far inside it — the bound is
        // what keeps a long pause O(log n).
        let timeline = PlaybackTimeline(segments: [seg(0, 500)])
        #expect(timeline.activeIndex(at: 100) == 0)
        #expect(timeline.activeIndex(at: 400) == nil)
    }

    @Test(arguments: [
        (0.0, "0:00"), (59.9, "0:59"), (60, "1:00"), (3599, "59:59"), (3600, "1:00:00"),
        (3725, "1:02:05"), (-3, "0:00"), (.nan, "0:00"), (.infinity, "0:00"),
    ] as [(TimeInterval, String)])
    func clockFormats(seconds: TimeInterval, expected: String) {
        #expect(PlaybackTimeline.clock(seconds) == expected)
    }
}
