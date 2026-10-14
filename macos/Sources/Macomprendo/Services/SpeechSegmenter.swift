import Foundation
import SherpaOnnxC

/// Finds speech in a stream of 16 kHz mono PCM.
protocol SpeechSegmenting: Sendable {
    /// A fresh detector for one recording. Sessions keep state between `accept` calls and are
    /// used from one task at a time.
    func makeSession() throws -> any SpeechSegmentingSession
}

protocol SpeechSegmentingSession: AnyObject {
    /// Feeds samples; returns the segments completed by them, each at most
    /// `SpeechSegmentSplitter.maximumDuration` long.
    func accept(_ samples: [Float]) -> [SpeechSegment]
    /// Ends the stream and returns whatever speech was still open.
    func finish() -> [SpeechSegment]
}

/// Silero VAD through the vendored sherpa-onnx C API, with the model bundled in
/// `Resources/SpeechDetection` (ADR-0015).
struct SherpaSileroSegmenter: SpeechSegmenting {
    static let sampleRate = 16_000

    private let modelURL: URL?

    init(modelURL: URL? = ResourceBundle.current.url(forResource: "silero_vad",
                                                      withExtension: "onnx",
                                                      subdirectory: "SpeechDetection")) {
        self.modelURL = modelURL
    }

    func makeSession() throws -> any SpeechSegmentingSession {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            throw MacomprendoError.speechDetector("silero_vad.onnx is not in the app bundle")
        }
        return try SherpaSileroSession(modelPath: modelURL.path)
    }
}

private final class SherpaSileroSession: SpeechSegmentingSession {
    private let detector: OpaquePointer
    private let rate = SherpaSileroSegmenter.sampleRate

    init(modelPath: String) throws {
        var config = SherpaOnnxVadModelConfig()
        let created: OpaquePointer? = modelPath.withCString { model in
            "cpu".withCString { provider in
                config.silero_vad.model = model
                config.silero_vad.threshold = 0.5
                config.silero_vad.min_silence_duration = 0.5
                config.silero_vad.min_speech_duration = 0.25
                // The detector only *encourages* a split here; SpeechSegmentSplitter enforces it.
                config.silero_vad.max_speech_duration = Float(SpeechSegmentSplitter.maximumDuration)
                config.silero_vad.window_size = 512
                config.sample_rate = Int32(SherpaSileroSegmenter.sampleRate)
                config.num_threads = 1
                config.provider = provider
                config.debug = 0
                return SherpaOnnxCreateVoiceActivityDetector(&config, 60)
            }
        }
        guard let created else {
            throw MacomprendoError.speechDetector("sherpa-onnx rejected the model")
        }
        detector = created
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(detector)
    }

    func accept(_ samples: [Float]) -> [SpeechSegment] {
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, buffer.baseAddress,
                                                         Int32(buffer.count))
        }
        return drain()
    }

    func finish() -> [SpeechSegment] {
        SherpaOnnxVoiceActivityDetectorFlush(detector)
        return drain()
    }

    private func drain() -> [SpeechSegment] {
        var segments: [SpeechSegment] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            guard let front = SherpaOnnxVoiceActivityDetectorFront(detector) else { break }
            let segment = front.pointee
            let samples = Array(UnsafeBufferPointer(start: segment.samples, count: Int(segment.n)))
            SherpaOnnxDestroySpeechSegment(front)
            SherpaOnnxVoiceActivityDetectorPop(detector)
            segments += SpeechSegmentSplitter.split(
                SpeechSegment(start: Double(segment.start) / Double(rate),
                              samples: samples, sampleRate: rate))
        }
        return segments
    }
}
