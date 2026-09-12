import AVFoundation
import Foundation

/// Encodes the 16 kHz mono Float32 PCM the recorder keeps into an audio file on disk.
protocol DictationAudioEncoding: Sendable {
    /// Encodes `pcm` to `url`, creating intermediate directories.
    /// Throws `MacomprendoError.audioEncoding` on any failure.
    func encode(_ pcm: [Float], sampleRate: Int, to url: URL) async throws
}

/// AAC at 48 kbit/s into `.m4a`, written with `AVAssetWriter` rather than
/// `AVAudioFile`: the latter reserves a ~22 KB `free` atom in every file, nine times
/// the payload of a three-second dictation (ADR-0011).
struct AACDictationAudioEncoder: DictationAudioEncoding {

    /// Frames handed to the writer input at a time.
    private static let chunkFrames = 8_192
    private static let bitRate = 48_000

    func encode(_ pcm: [Float], sampleRate: Int, to url: URL) async throws {
        guard !pcm.isEmpty else {
            throw MacomprendoError.audioEncoding("there was nothing to encode")
        }
        guard sampleRate > 0 else {
            throw MacomprendoError.audioEncoding("the sample rate \(sampleRate) is not valid")
        }

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
        } catch {
            throw MacomprendoError.audioEncoding(error.localizedDescription)
        }
        // A stale file at the destination makes `AVAssetWriter` refuse to start.
        // A directory there is left alone, so `startWriting()` reports the conflict.
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            try? FileManager.default.removeItem(at: url)
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw MacomprendoError.audioEncoding(error.localizedDescription)
        }

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.bitRate
        ])
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw MacomprendoError.audioEncoding("the AAC encoder rejected 16 kHz mono audio")
        }
        writer.add(input)

        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw Self.failure(writer, fallback: "the writer would not start")
        }
        writer.startSession(atSourceTime: .zero)

        do {
            try await Self.append(pcm, sampleRate: sampleRate, to: input)
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()

        // A failed `AVAssetWriter` does not throw on its own.
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Self.failure(writer, fallback: "the file could not be written")
        }
    }

    private static func append(_ pcm: [Float], sampleRate: Int,
                               to input: AVAssetWriterInput) async throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(sampleRate),
                                         channels: 1, interleaved: false) else {
            throw MacomprendoError.audioEncoding("16 kHz mono is not a usable input format")
        }

        var offset = 0
        while offset < pcm.count {
            let frames = min(chunkFrames, pcm.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(frames)),
                  let channel = buffer.floatChannelData?[0] else {
                throw MacomprendoError.audioEncoding("a sample buffer could not be allocated")
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            pcm.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + offset, count: frames)
            }

            let sample = try sampleBuffer(from: buffer,
                                          at: CMTime(value: CMTimeValue(offset),
                                                     timescale: CMTimeScale(sampleRate)))
            try await waitUntilReady(input)
            guard input.append(sample) else {
                throw MacomprendoError.audioEncoding("the encoder rejected a sample buffer")
            }
            offset += frames
        }
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer,
                                     at time: CMTime) throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil,
            formatDescription: buffer.format.formatDescription, sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)),
                presentationTimeStamp: time, decodeTimeStamp: .invalid)],
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw MacomprendoError.audioEncoding("a sample buffer could not be created (\(status))")
        }

        let attached = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList)
        guard attached == noErr else {
            throw MacomprendoError.audioEncoding("audio could not be attached to a sample buffer (\(attached))")
        }
        return sample
    }

    /// `AVAssetWriterInput` has no async readiness signal, so poll it. The encoder
    /// drains a 16 kHz mono stream far faster than it is fed, so this rarely sleeps.
    private static func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func failure(_ writer: AVAssetWriter, fallback: String) -> MacomprendoError {
        .audioEncoding(writer.error?.localizedDescription ?? fallback)
    }
}
