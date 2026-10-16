import Foundation
import SherpaOnnxC

/// Finds speech in a stream of 16 kHz mono PCM.
protocol SpeechSegmenting: Sendable {
    /// A fresh detector for one recording. Sessions keep state between `accept` calls and are
    /// used from one task at a time.
    /// `joinGap`: how close two speech regions must be to share a segment
    /// (`SpeechSpanAssembler.joinGap` for a file, `callJoinGap` for a call track).
    func makeSession(joinGap: TimeInterval) throws -> any SpeechSegmentingSession
}

protocol SpeechSegmentingSession: AnyObject {
    /// Feeds samples; returns the segments completed by them, each at most
    /// `SpeechSegmentSplitter.maximumDuration + SpeechSegmentSplitter.minimumRemainder` long —
    /// the splitter never cuts a remainder under `minimumRemainder`.
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

    func makeSession(joinGap: TimeInterval) throws -> any SpeechSegmentingSession {
        guard let modelURL, FileManager.default.fileExists(atPath: modelURL.path) else {
            throw MacomprendoError.speechDetector("silero_vad.onnx is not in the app bundle")
        }
        return try SherpaSileroSession(modelPath: modelURL.path, joinGap: joinGap)
    }
}

/// One recording's detector — and one `SpeechSpanAssembler` that turns its regions into padded,
/// joined segments: every accepted chunk goes to both, each completed region goes to the
/// assembler, and the assembler's segments are returned (spec: Pipeline step 3).
private final class SherpaSileroSession: SpeechSegmentingSession {
    private let detector: OpaquePointer
    private let assembler: SpeechSpanAssembler
    private let rate = SherpaSileroSegmenter.sampleRate

    init(modelPath: String, joinGap: TimeInterval) throws {
        var config = SherpaOnnxVadModelConfig()
        let created: OpaquePointer? = modelPath.withCString { model in
            "cpu".withCString { provider in
                config.silero_vad.model = model
                config.silero_vad.threshold = 0.5
                config.silero_vad.min_silence_duration = 0.5
                // The window and the minimum speech duration are shared with the assembler: it
                // keeps a lookback sized from them, because sherpa backdates a region's start by
                // `2 · window_size + min_speech_duration` behind the moment it first sees speech
                // (`voice-activity-detector.cc`, `AcceptWaveform`).
                config.silero_vad.min_speech_duration =
                    Float(SpeechSpanAssembler.detectorMinSpeechDuration)
                // The detector only *encourages* a split here; SpeechSpanAssembler enforces it.
                config.silero_vad.max_speech_duration = Float(SpeechSegmentSplitter.maximumDuration)
                config.silero_vad.window_size = Int32(SpeechSpanAssembler.detectorWindowSize)
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
        assembler = SpeechSpanAssembler(sampleRate: rate, joinGap: joinGap)
    }

    deinit {
        SherpaOnnxDestroyVoiceActivityDetector(detector)
    }

    func accept(_ samples: [Float]) -> [SpeechSegment] {
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxVoiceActivityDetectorAcceptWaveform(detector, buffer.baseAddress,
                                                         Int32(buffer.count))
        }
        let regions = drainRegions()
        // While the detector is inside speech it may still report a region starting inside the
        // assembler's join window, so the assembler must not close a span by time yet.
        let speechInProgress = SherpaOnnxVoiceActivityDetectorDetected(detector) != 0
        return assembler.accept(samples: samples, regions: regions,
                                speechInProgress: speechInProgress)
    }

    func finish() -> [SpeechSegment] {
        SherpaOnnxVoiceActivityDetectorFlush(detector)
        // Everything completed is known by now, so all regions are applied before the assembler
        // closes what is left.
        var segments = assembler.accept(samples: [], regions: drainRegions(),
                                        speechInProgress: false)
        segments += assembler.finish()
        return segments
    }

    /// Completed regions, in stream samples. A degenerate segment (no samples) is dropped rather
    /// than treated as a region.
    private func drainRegions() -> [SpeechSpanAssembler.Region] {
        var regions: [SpeechSpanAssembler.Region] = []
        while SherpaOnnxVoiceActivityDetectorEmpty(detector) == 0 {
            guard let front = SherpaOnnxVoiceActivityDetectorFront(detector) else { break }
            let segment = front.pointee
            let start = Int(segment.start)
            let count = Int(segment.n)
            SherpaOnnxDestroySpeechSegment(front)
            SherpaOnnxVoiceActivityDetectorPop(detector)
            guard count > 0 else { continue }
            regions.append(SpeechSpanAssembler.Region(startSample: start, endSample: start + count))
        }
        return regions
    }
}
