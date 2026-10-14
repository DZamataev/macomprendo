import AVFoundation
import Foundation

/// A file opened for decoding: its length, and its audio as 16 kHz mono chunks.
struct DecodedAudio: Sendable {
    /// Seconds of the whole file, regardless of where decoding starts.
    let duration: TimeInterval
    /// Where `chunks` begins, in seconds from the start of the file.
    let startOffset: TimeInterval
    let chunks: AsyncThrowingStream<[Float], Error>
}

protocol MediaAudioDecoding: Sendable {
    /// Opens the first audio track of `url` and decodes it from `start` seconds on.
    func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio
}

/// AVFoundation decoding: anything QuickTime Player opens, audio or video, resampled and
/// downmixed by `AVAssetReader` itself so the whole file is never held in memory.
struct AVAssetMediaDecoder: MediaAudioDecoding {
    static let sampleRate = 16_000

    func open(_ url: URL, from start: TimeInterval) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
            duration = try await asset.load(.duration)
        } catch {
            throw MacomprendoError.mediaUnreadable(error.localizedDescription)
        }
        guard let track = tracks.first else { throw MacomprendoError.noAudioTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MacomprendoError.mediaUnreadable(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MacomprendoError.mediaUnreadable("the audio track cannot be converted")
        }
        reader.add(output)
        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        reader.timeRange = CMTimeRange(start: startTime, end: .positiveInfinity)
        guard reader.startReading() else {
            throw MacomprendoError.mediaUnreadable(
                reader.error?.localizedDescription ?? "decoding could not start")
        }

        let box = ReaderBox(reader: reader, output: output)
        let chunks = AsyncThrowingStream<[Float], Error> { continuation in
            let task = Task.detached {
                do {
                    while let samples = try box.next() {
                        try Task.checkCancellation()
                        if !samples.isEmpty { continuation.yield(samples) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                box.cancel()
            }
        }
        let seconds = duration.seconds
        return DecodedAudio(duration: seconds.isFinite ? seconds : 0,
                            startOffset: max(0, start),
                            chunks: chunks)
    }
}

/// `AVAssetReader` is not `Sendable`; this box is only touched by the decoding task and by
/// `cancel()`, which `AVAssetReader.cancelReading()` documents as safe from another thread.
private final class ReaderBox: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
    }

    /// The next buffer's samples; `nil` at the end of the file.
    func next() throws -> [Float]? {
        guard let buffer = output.copyNextSampleBuffer() else {
            if reader.status == .failed {
                throw MacomprendoError.mediaUnreadable(
                    reader.error?.localizedDescription ?? "decoding failed")
            }
            return nil
        }
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                       destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else {
            throw MacomprendoError.mediaUnreadable("a decoded buffer could not be read")
        }
        return samples
    }

    func cancel() {
        reader.cancelReading()
    }
}
