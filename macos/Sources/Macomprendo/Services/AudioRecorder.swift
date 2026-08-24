// @preconcurrency: AVFAudio's completion-handler based APIs (AVAudioConverter.convert,
// the input tap block) predate Swift concurrency and aren't Sendable-audited, so Swift 6
// strict concurrency treats every capture crossing them as a potential data race even
// though they are, in practice, called synchronously on the calling thread.
@preconcurrency import AVFoundation
import Foundation

protocol AudioRecording: AnyObject, Sendable {
    /// RMS level 0…1, roughly ten values per second while recording.
    var level: AsyncStream<Float> { get }
    func start() async throws
    /// Returns everything captured since `start()`, as 16 kHz mono Float32 PCM.
    func stop() async -> [Float]
    var isRecording: Bool { get async }
}

/// Records the default input device through `AVAudioEngine` and converts it to
/// 16 kHz mono Float32 — the format whisper.cpp and the OpenAI audio endpoint expect.
///
/// When the recording reaches `maxDuration` the engine is stopped and no further
/// audio is accumulated; the next `stop()` returns the capped audio.
final class AVAudioEngineRecorder: AudioRecording, @unchecked Sendable {
    static let targetSampleRate: Double = 16_000

    let level: AsyncStream<Float>

    private let levelContinuation: AsyncStream<Float>.Continuation
    private let engine = AVAudioEngine()
    private let maxSamples: Int
    private let lock = NSLock()

    private var samples: [Float] = []
    private var recording = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var resampler = PCMResampler(inputRate: 48_000,
                                         outputRate: AVAudioEngineRecorder.targetSampleRate)

    init(maxDuration: TimeInterval = 300) {
        maxSamples = Int(maxDuration * AVAudioEngineRecorder.targetSampleRate)
        var continuation: AsyncStream<Float>.Continuation!
        level = AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation = $0 }
        levelContinuation = continuation
    }

    var isRecording: Bool { lock.withLock { recording } }

    func start() throws {
        // Guard against a second start() while already recording: AVAudioEngine's
        // installTap(onBus:) traps if a tap is installed twice on the same bus, so this
        // must be checked before any engine work below. Not covered by a unit test that
        // exercises the real engine (would require actual mic hardware in CI); covered
        // by the manual dictation-hotkey walkthrough in docs/SMOKE_TEST.md instead.
        guard !isRecording else {
            throw MacomprendoError.audio("Recording is already in progress.")
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw MacomprendoError.audio("No microphone input is available.")
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.targetSampleRate,
                                         channels: 1,
                                         interleaved: false) else {
            throw MacomprendoError.audio("Could not create the 16 kHz recording format.")
        }

        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            recording = true
            targetFormat = target
            converter = AVAudioConverter(from: inputFormat, to: target)
            resampler = PCMResampler(inputRate: inputFormat.sampleRate,
                                     outputRate: Self.targetSampleRate)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.withLock { recording = false }
            throw MacomprendoError.audio("Could not start the audio engine: \(error.localizedDescription)")
        }
        Log.audio.info("Recording started at \(inputFormat.sampleRate, privacy: .public) Hz")
    }

    func stop() -> [Float] {
        let captured: [Float] = lock.withLock {
            recording = false
            let collected = samples
            samples = []
            return collected
        }
        stopEngine()
        Log.audio.info("Recording stopped, \(captured.count, privacy: .public) samples")
        return captured
    }

    // MARK: - Tap

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        var reachedCap = false
        let converted: [Float] = lock.withLock {
            guard recording else { return [] }
            let mono = convertLocked(buffer)
            guard !mono.isEmpty else { return [] }
            let room = maxSamples - samples.count
            guard room > 0 else {
                recording = false
                reachedCap = true
                return []
            }
            samples.append(contentsOf: mono.prefix(room))
            if samples.count >= maxSamples {
                recording = false
                reachedCap = true
            }
            return mono
        }

        if reachedCap {
            Task.detached { [weak self] in self?.stopEngine() }
        }
        if !converted.isEmpty {
            levelContinuation.yield(AudioMath.level(fromRMS: AudioMath.rms(converted)))
        }
        if reachedCap {
            // The engine just auto-stopped with no further `stop()` call coming from the
            // caller — finishing the stream is the only signal a consumer (like
            // `DictationController`'s level loop) gets that this recording session is
            // over, so it can transcribe instead of sitting frozen in `.recording`.
            levelContinuation.finish()
        }
    }

    /// Must be called with `lock` held.
    private func convertLocked(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter, let target = targetFormat else {
            return resampler.resample(Self.monoSamples(buffer))
        }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }

        // `AVAudioConverter.convert(to:error:withInputFrom:)` declares its pull block as
        // `@Sendable`, so Swift 6 treats this capture as if it could run concurrently.
        // In practice the block is called synchronously and repeatedly on the calling
        // thread until this function returns — `nonisolated(unsafe)` is safe here.
        nonisolated(unsafe) var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    private func stopEngine() {
        guard engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let data = buffer.floatChannelData else { return [] }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        if channels == 1 {
            return Array(UnsafeBufferPointer(start: data[0], count: frames))
        }
        var mixed = [Float](repeating: 0, count: frames)
        for channel in 0..<channels {
            let pointer = data[channel]
            for frame in 0..<frames { mixed[frame] += pointer[frame] }
        }
        let scale = 1 / Float(channels)
        for frame in 0..<frames { mixed[frame] *= scale }
        return mixed
    }
}
