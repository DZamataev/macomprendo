import AVFoundation
import Foundation

/// A file opened for decoding: its length, and its audio as 16 kHz mono chunks.
struct DecodedAudio: Sendable {
    /// Seconds of the whole file, regardless of where decoding starts.
    let duration: TimeInterval
    /// The requested start, in seconds from the start of the file. For compressed sources the
    /// first decoded sample may sit slightly before it: `AVAssetReader` begins at a sync point.
    let startOffset: TimeInterval
    /// 16 kHz mono samples, pulled from the file one buffer at a time. Nothing is decoded until
    /// the consumer asks for the next chunk, so a slow consumer never buffers the whole file.
    let chunks: AsyncThrowingStream<[Float], Error>
    /// Test-only (internal): how many source buffers the decoder has pulled so far. Lets a test
    /// prove the stream is pull-based without exposing anything publicly.
    let buffersPulled: @Sendable () -> Int

    init(duration: TimeInterval, startOffset: TimeInterval,
         chunks: AsyncThrowingStream<[Float], Error>,
         buffersPulled: @escaping @Sendable () -> Int = { 0 }) {
        self.duration = duration
        self.startOffset = startOffset
        self.chunks = chunks
        self.buffersPulled = buffersPulled
    }
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
        // Pull-based: the unfolding closure runs only when the consumer asks for the next chunk,
        // so decoding never races ahead of a slow consumer. Empty buffers are skipped inside the
        // box and `nil` ends the stream. Cancellation is checked on every pull, and the reader is
        // cancelled when the box goes away (the consumer dropping the iterator releases it). No
        // dropping buffering policy is used: losing audio would be worse.
        let chunks = AsyncThrowingStream<[Float], Error>(unfolding: {
            try Task.checkCancellation()
            return try box.nextNonEmpty()
        })
        let seconds = duration.seconds
        return DecodedAudio(duration: seconds.isFinite ? seconds : 0,
                            startOffset: max(0, start),
                            chunks: chunks,
                            buffersPulled: { box.buffersPulled })
    }
}

/// `AVAssetReader` is not `Sendable`; this box is only touched by the stream's unfolding closure
/// and by `deinit`, which `AVAssetReader.cancelReading()` documents as safe from another thread.
private final class ReaderBox: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    /// Test-only observable of how far decoding has advanced.
    private(set) var buffersPulled = 0

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput) {
        self.reader = reader
        self.output = output
    }

    deinit {
        // Stops decoding as soon as nothing can pull from the stream any more.
        reader.cancelReading()
    }

    /// The next non-empty buffer's samples; `nil` at the end of the file. Buffers that carry no
    /// samples are skipped here rather than yielded, so consumers never see an empty chunk.
    func nextNonEmpty() throws -> [Float]? {
        while true {
            guard let samples = try next() else { return nil }
            if !samples.isEmpty { return samples }
        }
    }

    /// The next buffer's samples; `nil` at the end of the file.
    private func next() throws -> [Float]? {
        buffersPulled += 1
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
}
