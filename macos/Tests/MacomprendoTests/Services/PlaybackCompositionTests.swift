import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@MainActor
struct PlaybackCompositionTests {
    /// A mono 48 kHz WAV of `seconds` length in a fresh temp directory.
    private func wav(_ seconds: Double, in directory: URL, name: String) throws -> URL {
        let samples = [Float](repeating: 0.1, count: Int(seconds * 48_000))
        let url = directory.appendingPathComponent(name)
        try WAVEncoder.encode(pcm: samples, sampleRate: 48_000).write(to: url)
        return url
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlaybackCompositionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFileSourceLoadsWithTheFileDuration() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try wav(0.5, in: dir, name: "a.wav")

        let asset = try await PlaybackComposition.make(.file(url))

        #expect(abs(asset.duration - 0.5) < 0.01)
        #expect(asset.trackIDs.isEmpty)
    }

    @Test func aFileWithoutSoundIsUnavailable() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: url)

        await #expect(throws: MacomprendoError.transcriptPlaybackUnavailable("the file has no playable sound")) {
            _ = try await PlaybackComposition.make(.file(url))
        }
    }

    @Test func aCallPlacesEachTrackAtItsOffset() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = try wav(0.4, in: dir, name: "me.wav")
        let others = try wav(0.3, in: dir, name: "others.wav")

        let asset = try await PlaybackComposition.make(.call([
            PlaybackTrack(speaker: .me, url: me, offset: 0),
            PlaybackTrack(speaker: .others, url: others, offset: 0.25),
        ]))

        #expect(Set(asset.trackIDs.keys) == [.me, .others])
        #expect(abs(asset.duration - 0.55) < 0.01)
        let composition = try #require(asset.asset as? AVMutableComposition)
        for (speaker, offset) in [(TranscriptSpeaker.me, 0.0), (.others, 0.25)] {
            let track = try #require(composition.track(withTrackID: asset.trackIDs[speaker]!))
            let firstMedia = try #require(track.segments.first { !$0.isEmpty })
            #expect(abs(firstMedia.timeMapping.target.start.seconds - offset) < 0.001)
        }
    }

    @Test func anUnreadableCallTrackIsLeftOutAndTheOtherPlays() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let me = try wav(0.2, in: dir, name: "me.wav")
        let broken = dir.appendingPathComponent("others.m4a")
        try Data("broken".utf8).write(to: broken)

        let asset = try await PlaybackComposition.make(.call([
            PlaybackTrack(speaker: .me, url: me, offset: 0),
            PlaybackTrack(speaker: .others, url: broken, offset: 0.1),
        ]))

        #expect(Set(asset.trackIDs.keys) == [.me])
    }

    @Test func aCallWithNoReadableTrackIsUnavailable() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let broken = dir.appendingPathComponent("me.m4a")
        try Data("broken".utf8).write(to: broken)

        await #expect(throws: MacomprendoError.transcriptPlaybackUnavailable("no track of the recording can be read")) {
            _ = try await PlaybackComposition.make(.call([PlaybackTrack(speaker: .me, url: broken, offset: 0)]))
        }
    }

    @Test func theMixSilencesTheMutedSide() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = try await PlaybackComposition.make(.call([
            PlaybackTrack(speaker: .me, url: try wav(0.2, in: dir, name: "me.wav"), offset: 0),
            PlaybackTrack(speaker: .others, url: try wav(0.2, in: dir, name: "o.wav"), offset: 0),
        ]))

        let mix = try #require(PlaybackComposition.audioMix(for: asset, muted: [.others]))

        func volume(_ speaker: TranscriptSpeaker) -> Float? {
            guard let params = mix.inputParameters.first(where: { $0.trackID == asset.trackIDs[speaker] })
            else { return nil }
            var start: Float = -1, end: Float = -1
            var range = CMTimeRange.zero
            _ = params.getVolumeRamp(for: .zero, startVolume: &start, endVolume: &end, timeRange: &range)
            return start
        }
        #expect(volume(.me) == 1)
        #expect(volume(.others) == 0)
    }

    @Test func aFileHasNoMix() async throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let asset = try await PlaybackComposition.make(.file(try wav(0.2, in: dir, name: "a.wav")))
        #expect(PlaybackComposition.audioMix(for: asset, muted: []) == nil)
    }
}
