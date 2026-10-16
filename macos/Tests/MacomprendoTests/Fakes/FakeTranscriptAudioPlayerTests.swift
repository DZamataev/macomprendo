import Foundation
import Testing
@testable import Macomprendo

@MainActor
struct FakeTranscriptAudioPlayerTests {
    @Test func aHeldLoadWaitsForItsRelease() async throws {
        let player = FakeTranscriptAudioPlayer()
        player.holdLoads = true
        let load = Task { try await player.load(.file(URL(fileURLWithPath: "/a.m4a"))) }
        while player.pendingLoads == 0 { await Task.yield() }
        player.releaseLoad()
        #expect(try await load.value.duration == 60)
    }
}
