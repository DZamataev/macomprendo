import AVFoundation
import Foundation

/// Places one track's chunks on the session clock. Pure, so the gap arithmetic is unit-testable
/// without audio hardware.
struct TrackTimeline: Sendable, Equatable {
    /// A hole shorter than this is host-clock jitter, not a real gap.
    static let minimumGap: TimeInterval = 0.05

    let sampleRate: Double
    let sessionStart: TimeInterval
    private(set) var firstSampleTime: TimeInterval?
    private(set) var framesWritten = 0

    init(sampleRate: Double, sessionStart: TimeInterval) {
        self.sampleRate = sampleRate
        self.sessionStart = sessionStart
    }

    /// Frames of silence to write before a chunk of `frames` whose first sample is at `time`
    /// (host seconds). Also counts the chunk (and the silence) into `framesWritten`.
    mutating func place(frames: Int, at time: TimeInterval) -> Int {
        guard let firstSampleTime else {
            self.firstSampleTime = time
            framesWritten += frames
            return 0
        }
        let expected = firstSampleTime + Double(framesWritten) / sampleRate
        let gap = time - expected
        let pad = gap >= Self.minimumGap ? Int((gap * sampleRate).rounded()) : 0
        framesWritten += pad + frames
        return pad
    }

    /// Seconds from the session start to the track's first sample, `nil` until one arrives.
    var startOffset: TimeInterval? {
        firstSampleTime.map { $0 - sessionStart }
    }
}

/// Receives one track's audio: 48 kHz mono Float32, `time` = host seconds of the first sample.
protocol CallAudioSink: AnyObject, Sendable {
    func consume(_ samples: [Float], at time: TimeInterval)
}

protocol CallTrackWriting: CallAudioSink {
    var startOffset: TimeInterval? { get }
    /// Flushes and closes the file. Throws `callRecordingWriteFailed`.
    func finish() async throws
}

typealias CallTrackWriterFactory = @Sendable (_ url: URL, _ sessionStart: TimeInterval,
    _ onFailure: @escaping @Sendable (MacomprendoError) -> Void) throws -> any CallTrackWriting

/// Writes one track's audio as a fragmented AAC `.m4a` on the session clock.
///
/// Real-time threads only enqueue; every `AVAssetWriter` interaction runs on a private serial
/// queue, so a slow encoder never blocks capture. The 1 s fragment interval bounds what a crash
/// loses to the last second and keeps the partial file playable.
final class AssetCallTrackWriter: CallTrackWriting, @unchecked Sendable {
    static let sampleRate: Double = 48_000
    static let bitRate = 48_000
    /// How long `finish()` waits for an encoder that has not reported ready before giving up on
    /// the queued tail. `finish()` is awaited on the stop path and by `AppModel.shutdown()`, so
    /// an encoder that never becomes ready must not hang them.
    static let maximumFinishWait: TimeInterval = 5

    static let factory: CallTrackWriterFactory = { url, sessionStart, onFailure in
        try AssetCallTrackWriter(url: url, sessionStart: sessionStart, onFailure: onFailure)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let onFailure: @Sendable (MacomprendoError) -> Void
    private let maximumFinishWait: TimeInterval
    /// Whether the encoder can take another buffer; `nil` asks the real `AVAssetWriterInput`.
    /// A seam for the finish deadline test: a live encoder cannot be made to refuse data.
    private let encoderReady: (@Sendable () -> Bool)?
    private let queue = DispatchQueue(label: "com.dzamataev.macomprendo.call-track-writer")

    private let lock = NSLock()
    /// Guarded by `lock`: every append asks the timeline where its chunk goes.
    private var timeline: TrackTimeline
    /// Guarded by `lock`. `failed` is set on the first failure, `closed` when `finish()` runs;
    /// either drops later audio.
    private var failed = false
    private var closed = false

    /// Buffers the encoder was not ready for, drained before the next append and in `finish()`.
    /// Only touched on `queue`.
    private var pending: [CMSampleBuffer] = []

    init(url: URL, sessionStart: TimeInterval,
         onFailure: @escaping @Sendable (MacomprendoError) -> Void,
         maximumFinishWait: TimeInterval = AssetCallTrackWriter.maximumFinishWait,
         encoderReady: (@Sendable () -> Bool)? = nil) throws {
        self.onFailure = onFailure
        self.maximumFinishWait = maximumFinishWait
        self.encoderReady = encoderReady
        timeline = TrackTimeline(sampleRate: Self.sampleRate, sessionStart: sessionStart)

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        } catch {
            throw MacomprendoError.callRecordingWriteFailed(error.localizedDescription)
        }
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)

        input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: Self.bitRate,
        ])
        // The producer is a live capture, not a file being copied as fast as the disk allows.
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MacomprendoError.callRecordingWriteFailed(
                "the AAC encoder rejected 48 kHz mono audio")
        }
        writer.add(input)

        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: url)
            throw Self.failure(writer, fallback: "the track file could not be opened")
        }
        writer.startSession(atSourceTime: .zero)
    }

    var startOffset: TimeInterval? {
        lock.withLock { timeline.startOffset }
    }

    func consume(_ samples: [Float], at time: TimeInterval) {
        // An empty chunk would claim the track's first sample without writing any audio.
        guard !samples.isEmpty else { return }
        queue.async { [self] in append(samples, at: time) }
    }

    func finish() async throws {
        let drainFailure = await withCheckedContinuation {
            (continuation: CheckedContinuation<String?, Never>) in
            queue.async { [self] in
                lock.withLock { closed = true }
                let drainFailure = drainPending(waitsForInput: true)
                input.markAsFinished()
                continuation.resume(returning: drainFailure)
            }
        }
        await writer.finishWriting()
        if let drainFailure {
            throw MacomprendoError.callRecordingWriteFailed(drainFailure)
        }
        // A failed `AVAssetWriter` does not throw on its own.
        guard writer.status == .completed else {
            throw Self.failure(writer, fallback: "the track file could not be written")
        }
    }

    /// Runs on `queue`: places the chunk on the timeline, then queues the padding and the audio.
    private func append(_ samples: [Float], at time: TimeInterval) {
        guard lock.withLock({ !failed && !closed }) else { return }
        guard writer.status == .writing else {
            reportFailure(Self.reason(for: writer, fallback: "the track file could not be written"))
            return
        }

        let placed = lock.withLock {
            let pad = timeline.place(frames: samples.count, at: time)
            return (pad: pad, firstFrame: timeline.framesWritten - samples.count)
        }
        if placed.pad > 0,
           !appendBuffer(samples: nil, frames: placed.pad, atFrame: placed.firstFrame - placed.pad) {
            return
        }
        appendBuffer(samples: samples, frames: samples.count, atFrame: placed.firstFrame)
    }

    /// Describes a chunk as a sample buffer and hands it to the FIFO. `samples` `nil` means
    /// silence. False means the chunk was dropped and reported.
    @discardableResult
    private func appendBuffer(samples: [Float]?, frames: Int, atFrame frame: Int) -> Bool {
        guard let buffer = Self.makeSampleBuffer(samples: samples, frames: frames, atFrame: frame) else {
            reportFailure("a sample buffer could not be created")
            return false
        }
        pending.append(buffer)
        drainPending(waitsForInput: false)
        return true
    }

    /// Runs on `queue`. Appends from the FIFO while the encoder takes data; at `finish()` there is
    /// no next append to retry on, so the tail waits for the encoder instead of being dropped —
    /// but not past `maximumFinishWait`, because `finish()` is awaited on the stop path. Returns
    /// the reason the tail was not written, already reported through `onFailure`; `nil` when
    /// there is nothing to report — everything was written, or an append will retry next chunk.
    @discardableResult
    private func drainPending(waitsForInput: Bool) -> String? {
        let deadline = waitsForInput ? Date().addingTimeInterval(maximumFinishWait) : nil
        while !pending.isEmpty {
            guard writer.status == .writing else {
                pending.removeAll()
                let reason = Self.reason(for: writer, fallback: "the track file could not be written")
                reportFailure(reason)
                return reason
            }
            guard encoderReady?() ?? input.isReadyForMoreMediaData else {
                guard let deadline else { return nil }
                if Date() >= deadline {
                    pending.removeAll()
                    let reason = "the encoder did not accept the recording's remaining audio"
                    reportFailure(reason)
                    return reason
                }
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }
            let buffer = pending.removeFirst()
            guard input.append(buffer) else {
                pending.removeAll()
                let reason = Self.reason(for: writer, fallback: "the encoder rejected a sample buffer")
                reportFailure(reason)
                return reason
            }
        }
        return nil
    }

    /// Runs on `queue`. The first failure is reported once; every later chunk is dropped by
    /// `consume` and `append`.
    private func reportFailure(_ reason: String) {
        let isFirst = lock.withLock {
            guard !failed else { return false }
            failed = true
            return true
        }
        guard isFirst else { return }
        onFailure(.callRecordingWriteFailed(reason))
    }

    /// The construction `DictationAudioEncoder` uses, adapted to a queue that reports failures
    /// through `onFailure` rather than throwing.
    private static func makeSampleBuffer(samples: [Float]?, frames: Int,
                                         atFrame frame: Int) -> CMSampleBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        if let samples {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        } else {
            channel.update(repeating: 0, count: frames)
        }
        return sampleBuffer(from: buffer,
                            at: CMTime(value: CMTimeValue(frame),
                                       timescale: CMTimeScale(sampleRate)))
    }

    private static func sampleBuffer(from buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
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
        guard status == noErr, let sample else { return nil }

        let attached = CMSampleBufferSetDataBufferFromAudioBufferList(
            sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0,
            bufferList: buffer.audioBufferList)
        guard attached == noErr else { return nil }
        return sample
    }

    private static func failure(_ writer: AVAssetWriter, fallback: String) -> MacomprendoError {
        .callRecordingWriteFailed(reason(for: writer, fallback: fallback))
    }

    private static func reason(for writer: AVAssetWriter, fallback: String) -> String {
        writer.error?.localizedDescription ?? fallback
    }
}

/// Converts any PCM buffer to 48 kHz mono Float32. Keeps its converter while the input format is
/// unchanged; a device switch mid-recording changes it.
final class MonoResampler: @unchecked Sendable {
    private let targetRate: Double
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    init(targetRate: Double = 48_000) {
        self.targetRate = targetRate
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        return lock.withLock {
            guard let samples = convertUnlocked(buffer) else {
                Log.audio.error(
                    "the resampler dropped \(buffer.frameLength, privacy: .public) frames of \(buffer.format.sampleRate, privacy: .public) Hz audio")
                return []
            }
            return samples
        }
    }

    /// Callers hold `lock`: `AVAudioConverter` is not thread-safe.
    private func convertUnlocked(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate,
                                         channels: 1, interleaved: false) else { return nil }
        if converter == nil || !Self.matches(sourceFormat, buffer.format) {
            let fresh = AVAudioConverter(from: buffer.format, to: target)
            // Without this, a 2→1 conversion remaps and copies input channel 0, so the system
            // tap's right channel would never reach the mono track.
            fresh?.downmix = true
            converter = fresh
            sourceFormat = buffer.format
        }
        guard let converter else { return nil }

        let frames = Double(buffer.frameLength) * targetRate / buffer.format.sampleRate
        let capacity = Int(frames.rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(capacity)) else { return nil }

        // The block is typed `@Sendable` but `convert` calls it synchronously, so the frames it is
        // handed never cross a thread.
        nonisolated(unsafe) let source = buffer
        nonisolated(unsafe) var cursor = 0
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { requested, inputStatus in
            // The converter pulls its own packet size (~4096 frames) per request and ignores
            // whatever else a returned buffer holds, so hand it exactly the frames it asks for
            // from the cursor. `.endOfStream` instead of `.noDataNow` would park the converter in
            // its finished state, leaving every later same-format call silent.
            guard requested > 0, cursor < Int(source.frameLength) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            let count = min(Int(requested), Int(source.frameLength) - cursor)
            guard let chunk = Self.slice(source, from: cursor, frames: count) else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            cursor += count
            inputStatus.pointee = .haveData
            return chunk
        }
        guard status == .haveData || status == .inputRanDry,
              let channel = output.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }

    /// `frames` frames of `source` from `from` on, for one input block request. The converter
    /// consumes only what it asked for, so the rest of `source` stays for the next request.
    private static func slice(_ source: AVAudioPCMBuffer, from start: Int,
                              frames: Int) -> AVAudioPCMBuffer? {
        guard frames > 0, source.frameLength > 0, start + frames <= Int(source.frameLength),
              let output = AVAudioPCMBuffer(pcmFormat: source.format,
                                            frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        output.frameLength = AVAudioFrameCount(frames)
        let sourceList = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let outputList = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard sourceList.count == outputList.count else { return nil }
        for index in 0..<sourceList.count {
            let bytesPerFrame = Int(sourceList[index].mDataByteSize) / Int(source.frameLength)
            guard bytesPerFrame > 0, let sourceData = sourceList[index].mData,
                  let outputData = outputList[index].mData else { return nil }
            memcpy(outputData, sourceData.advanced(by: start * bytesPerFrame), frames * bytesPerFrame)
        }
        return output
    }

    private static func matches(_ lhs: AVAudioFormat?, _ rhs: AVAudioFormat) -> Bool {
        guard let lhs else { return false }
        return lhs.sampleRate == rhs.sampleRate && lhs.channelCount == rhs.channelCount
            && lhs.commonFormat == rhs.commonFormat && lhs.isInterleaved == rhs.isInterleaved
    }
}
