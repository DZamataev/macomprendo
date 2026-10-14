import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct MediaAudioDecoderTests {

    /// A 44.1 kHz stereo WAV of a 440 Hz tone: neither the rate nor the channel count the
    /// decoder emits, so the test proves it resamples and downmixes.
    private func writeTone(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("decoder-\(UUID().uuidString).wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * sin(2 * .pi * 440 * Float(frame) / 44_100)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func collect(_ audio: DecodedAudio) async throws -> [Float] {
        var all: [Float] = []
        for try await chunk in audio.chunks { all += chunk }
        return all
    }

    @Test func decodesToSixteenKilohertzMonoWithTheFileDuration() async throws {
        let url = try writeTone(seconds: 2)
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = try await AVAssetMediaDecoder().open(url, from: 0)
        let samples = try await collect(audio)

        #expect(abs(audio.duration - 2) < 0.01)
        #expect(audio.startOffset == 0)
        #expect(abs(samples.count - 32_000) < 400)
        #expect(samples.contains { abs($0) > 0.3 })
    }

    @Test func decodingFromAnOffsetSkipsTheStart() async throws {
        let url = try writeTone(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let audio = try await AVAssetMediaDecoder().open(url, from: 2)
        let samples = try await collect(audio)

        #expect(abs(audio.duration - 3) < 0.01)
        #expect(audio.startOffset == 2)
        #expect(abs(samples.count - 16_000) < 400)
    }

    @Test func aFileThatIsNotMediaIsUnreadable() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-media-\(UUID().uuidString).mp3")
        try Data("plain text, not audio".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        await #expect {
            _ = try await AVAssetMediaDecoder().open(url, from: 0)
        } throws: { error in
            guard let error = error as? MacomprendoError else { return false }
            if case .mediaUnreadable = error { return true }
            return error == .noAudioTrack
        }
    }
}

@Suite struct SherpaSileroSegmenterTests {

    @Test func theBundledModelLoads() throws {
        _ = try SherpaSileroSegmenter().makeSession()
    }

    @Test func aMissingModelIsASpeechDetectorError() {
        let segmenter = SherpaSileroSegmenter(modelURL: URL(fileURLWithPath: "/nonexistent.onnx"))
        #expect(throws: MacomprendoError.speechDetector("silero_vad.onnx is not in the app bundle")) {
            _ = try segmenter.makeSession()
        }
    }

    @Test func silenceYieldsNoSegments() throws {
        let session = try SherpaSileroSegmenter().makeSession()
        var segments = session.accept(Array(repeating: 0, count: 16_000 * 5))
        segments += session.finish()
        #expect(segments.isEmpty)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/say")))
    func spokenWordsBetweenSilencesYieldTimedSegments() async throws {
        let aiff = FileManager.default.temporaryDirectory
            .appendingPathComponent("segmenter-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: aiff) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "This is a short sentence for the speech detector."]
        try say.run()
        say.waitUntilExit()
        try #require(say.terminationStatus == 0)

        var speech: [Float] = []
        for try await chunk in try await AVAssetMediaDecoder().open(aiff, from: 0).chunks {
            speech += chunk
        }
        let silence = [Float](repeating: 0, count: 16_000 * 3)
        let stream = silence + speech + silence

        let session = try SherpaSileroSegmenter().makeSession()
        var segments: [SpeechSegment] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + 16_000, stream.count)
            segments += session.accept(Array(stream[offset..<end]))
            offset = end
        }
        segments += session.finish()

        let first = try #require(segments.first)
        // `say` itself leads with ~0.7 s of silence, so speech begins near 3.7 s.
        #expect(first.start > 2.5)
        #expect(first.start < 4.5)
        #expect(segments.allSatisfy { $0.duration <= SpeechSegmentSplitter.maximumDuration })
        let last = try #require(segments.last)
        #expect(last.end < Double(stream.count) / 16_000)
    }
}
