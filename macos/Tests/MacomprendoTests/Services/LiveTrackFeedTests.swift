import Foundation
import Testing
@testable import Macomprendo

@Suite struct LiveTrackFeedTests {
    private static let sessionStart: TimeInterval = 1_000
    private static func capture(seconds: Double, level: Float = 0.5) -> [Float] {
        [Float](repeating: level, count: Int(seconds * AssetCallTrackWriter.sampleRate))
    }

    private func drain(_ feed: LiveTrackFeed) async throws -> [Float] {
        feed.finish()
        var out: [Float] = []
        for try await chunk in feed.audio.chunks { out += chunk }
        return out
    }

    @Test func aTwoSecondHoleBecomesTwoSecondsOfSilenceAt16kHz() async throws {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart + 3)

        let out = try await drain(feed)
        #expect(abs(out.count - 64_000) <= 2)
        #expect(out[16_010..<47_990].allSatisfy { $0 == 0 })
        #expect(out[48_010..<63_990].allSatisfy { $0 == 0.5 })
    }

    @Test func aHoleUnderFiftyMillisecondsIsNotPadded() async throws {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart + 1.03)

        let out = try await drain(feed)
        #expect(abs(out.count - 32_000) <= 2)
    }

    @Test func theStartOffsetMatchesTheWritersTimeline() {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        #expect(feed.startOffset == nil)
        feed.consume(Self.capture(seconds: 0.01), at: Self.sessionStart + 0.25)
        var timeline = TrackTimeline(sampleRate: AssetCallTrackWriter.sampleRate,
                                     sessionStart: Self.sessionStart)
        _ = timeline.place(frames: 480, at: Self.sessionStart + 0.25)
        #expect(feed.startOffset == timeline.startOffset)
    }

    @Test func anEmptyChunkDoesNotClaimTheFirstSample() {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume([], at: Self.sessionStart + 5)
        #expect(feed.startOffset == nil)
    }

    @Test func finishEndsTheStreamAndLaterAudioIsDropped() async throws {
        let feed = LiveTrackFeed(sessionStart: Self.sessionStart)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart)
        let out = try await drain(feed)
        feed.consume(Self.capture(seconds: 1), at: Self.sessionStart + 1)
        #expect(abs(out.count - 16_000) <= 2)
    }
}
