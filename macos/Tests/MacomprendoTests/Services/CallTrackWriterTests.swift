import AVFoundation
import Foundation
import Testing
@testable import Macomprendo

@Suite struct TrackTimelineTests {

    @Test func firstChunkSetsOffsetWithoutPadding() {
        var t = TrackTimeline(sampleRate: 48_000, sessionStart: 100)
        #expect(t.place(frames: 480, at: 100.184) == 0)
        // `100.184 - 100` is 0.1839999999999975 in Double, so the offset is checked to tolerance.
        #expect(abs(t.startOffset! - 0.184) < 0.001, "offset")
        #expect(t.framesWritten == 480)
    }

    @Test func twoSecondHoleIsPadded() {
        var t = TrackTimeline(sampleRate: 48_000, sessionStart: 0)
        _ = t.place(frames: 48_000, at: 0)           // 0…1 s
        #expect(t.place(frames: 480, at: 3.0) == 96_000)
        #expect(t.framesWritten == 48_000 + 96_000 + 480)
    }

    @Test func thirtyMillisecondHoleIsNotPadded() {
        var t = TrackTimeline(sampleRate: 48_000, sessionStart: 0)
        _ = t.place(frames: 48_000, at: 0)
        #expect(t.place(frames: 480, at: 1.03) == 0)
    }

    @Test func lateClockNeverPadsNegative() {
        var t = TrackTimeline(sampleRate: 48_000, sessionStart: 0)
        _ = t.place(frames: 48_000, at: 0)
        #expect(t.place(frames: 480, at: 0.9) == 0)
    }
}

@Suite struct AssetCallTrackWriterTests {

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).m4a")
    }

    @Test func writesPlayableAACWithPaddedGap() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AssetCallTrackWriter(url: url, sessionStart: 10, onFailure: { _ in })
        let second = [Float](repeating: 0.1, count: 48_000)
        writer.consume(second, at: 10.5)              // 1 s at offset 0.5
        writer.consume(second, at: 13.5)              // 2 s hole → padded
        try await writer.finish()
        #expect(writer.startOffset == 0.5)
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 4.0) < 0.1)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC)
    }

    /// `finishWriting()` consolidates the fragments into a plain MP4, so the crash-safety the
    /// 1 s fragment interval buys is only observable while recording: a copy of the file as it
    /// stands mid-recording — the state a crash leaves behind — still opens and plays up to the
    /// last complete fragment.
    @Test func fragmentsReachDiskWhileRecording() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AssetCallTrackWriter(url: url, sessionStart: 0, onFailure: { _ in })
        let second = [Float](repeating: 0.1, count: 48_000)
        for index in 0..<3 {
            writer.consume(second, at: Double(index))
        }
        var fragmented = false
        let deadline = Date().addingTimeInterval(2)
        while !fragmented, Date() < deadline {
            fragmented = try topLevelBoxes(of: url).contains("moof")
            if !fragmented { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(fragmented, "no fragment reached disk within 2 s")

        let snapshot = temporaryURL()
        defer { try? FileManager.default.removeItem(at: snapshot) }
        try FileManager.default.copyItem(at: url, to: snapshot)
        let duration = try await AVURLAsset(url: snapshot).load(.duration).seconds
        #expect(duration > 1.5, "the mid-recording file reads only \(duration) s")
        try await writer.finish()
    }

    /// The top-level MP4 boxes of a file, in order. A box may carry a 64-bit `largesize`, which
    /// `AVAssetWriter` uses for the `mdat` it cannot size up front.
    private func topLevelBoxes(of url: URL) throws -> [String] {
        let bytes = [UInt8](try Data(contentsOf: url))
        var types: [String] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            var size = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if size == 1, offset + 16 <= bytes.count {
                size = 0
                for byte in bytes[(offset + 8)..<(offset + 16)] { size = size << 8 | Int(byte) }
            } else if size == 0 {
                size = bytes.count - offset
            }
            types.append(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self))
            guard size >= 8 else { break }
            offset += size
        }
        return types
    }

    @Test func unwritableLocationThrows() {
        #expect(throws: MacomprendoError.self) {
            _ = try AssetCallTrackWriter(url: URL(fileURLWithPath: "/nonexistent-dir/x.m4a"),
                                         sessionStart: 0, onFailure: { _ in })
        }
    }
}

@Suite struct MonoResamplerTests {

    private func stereoBuffer(left: Float, right: Float, frames: AVAudioFrameCount,
                              rate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: left, count: Int(frames))
        buffer.floatChannelData?[1].update(repeating: right, count: Int(frames))
        return buffer
    }

    private func monoBuffer(frames: AVAudioFrameCount, rate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData?[0].update(repeating: 0.5, count: Int(frames))
        return buffer
    }

    private func meanMagnitude(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0) { $0 + abs($1) } / Float(samples.count)
    }

    @Test func stereo44kBecomesMono48k() throws {
        let samples = MonoResampler().convert(stereoBuffer(left: 1, right: 0, frames: 44_100))
        #expect(abs(samples.count - 48_000) <= 64)
        // The track must hold audio, not silence: the frame count alone passes even when the
        // converter is fed a channel it ignores.
        #expect(meanMagnitude(samples) > 0.3,
                "converted \(samples.count) frames, mean magnitude \(meanMagnitude(samples))")
    }

    /// The tap is stereo; a 2→1 conversion that merely remaps channels would deliver the left
    /// channel of all system audio and drop the right one.
    @Test func stereoDownmixKeepsBothChannels() throws {
        let left = MonoResampler().convert(stereoBuffer(left: 1, right: 0, frames: 4_410))
        let right = MonoResampler().convert(stereoBuffer(left: 0, right: 1, frames: 4_410))
        #expect(meanMagnitude(left) > 0.3, "left-only input gave \(meanMagnitude(left))")
        #expect(meanMagnitude(right) > 0.3, "right-only input gave \(meanMagnitude(right))")
    }

    /// One resampler serves a whole call, one buffer per capture callback. A converter left in its
    /// end-of-stream state after the first buffer returns nothing for every later one.
    @Test func repeatedSameFormatBuffersKeepConverting() throws {
        let resampler = MonoResampler()
        let counts = (0..<10).map { _ in
            resampler.convert(stereoBuffer(left: 0.5, right: 0.5, frames: 4_410)).count
        }
        #expect(counts[0] > 0)
        for (index, count) in counts.enumerated().dropFirst() {
            #expect(abs(count - 4_800) <= 100, "buffer \(index) delivered \(count) frames")
        }
        #expect(abs(counts.reduce(0, +) - 48_000) <= 100,
                "ten 0.1 s buffers delivered \(counts.reduce(0, +)) frames")
    }

    /// An input already at the target rate must not degrade after the first buffer either.
    @Test func sameRateBuffersEachDeliverTheirFrames() throws {
        let resampler = MonoResampler()
        let counts = (0..<3).map { _ in resampler.convert(monoBuffer(frames: 4_800, rate: 48_000)).count }
        for (index, count) in counts.enumerated() {
            #expect(abs(count - 4_800) <= 64, "buffer \(index) delivered \(count) frames")
        }
    }

    @Test func aChangedInputFormatGetsANewConverter() throws {
        let resampler = MonoResampler()
        let stereo = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let first = AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 4_410)!
        first.frameLength = 4_410
        _ = resampler.convert(first)
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                 channels: 1, interleaved: false)!
        let second = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: 4_800)!
        second.frameLength = 4_800
        let samples = resampler.convert(second)
        #expect(abs(samples.count - 4_800) <= 8)
    }
}
