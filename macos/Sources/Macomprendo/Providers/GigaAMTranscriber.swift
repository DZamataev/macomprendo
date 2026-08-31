import Foundation
import SherpaOnnxC

/// Which sherpa-onnx offline model config a resolved file set maps onto. Pure, so the
/// mapping is unit-tested without the C API or the filesystem.
enum GigaAMConfigPlan: Sendable, Equatable {
    case ctc(model: URL, tokens: URL)
    case transducer(encoder: URL, decoder: URL, joiner: URL, tokens: URL)

    static func make(from files: [ModelFileRole: URL]) -> GigaAMConfigPlan? {
        guard let tokens = files[.tokens] else { return nil }
        if let model = files[.ctcModel] {
            return .ctc(model: model, tokens: tokens)
        }
        if let encoder = files[.encoder], let decoder = files[.decoder], let joiner = files[.joiner] {
            return .transducer(encoder: encoder, decoder: decoder, joiner: joiner, tokens: tokens)
        }
        return nil
    }

    /// The file whose name identifies this model in error messages.
    var identifyingFile: URL {
        switch self {
        case .ctc(let model, _): model
        case .transducer(let encoder, _, _, _): encoder
        }
    }

    /// Every file the recognizer needs. **Tokens is always last** — the C bridging below
    /// depends on that order.
    var requiredFiles: [URL] {
        switch self {
        case .ctc(let model, let tokens): [model, tokens]
        case .transducer(let encoder, let decoder, let joiner, let tokens):
            [encoder, decoder, joiner, tokens]
        }
    }
}

/// Owns a sherpa-onnx offline recognizer and frees it exactly once when the last reference
/// goes. A plain final class, as `WhisperContextBox` is, so `deinit` can call the C destructor
/// without fighting actor isolation.
private final class SherpaRecognizerBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(pointer)
    }
}

/// Local transcription through sherpa-onnx: Russian for the v3 entries, and Russian, English,
/// Kazakh, Kyrgyz and Uzbek for the multilingual ones.
///
/// The recognizer is created lazily on the first `transcribe` and stays resident, because
/// loading a 225 MB ONNX graph costs a couple of seconds. Serialisation is free: the type is
/// an actor, and a sherpa recognizer is not safe for concurrent decoding.
actor GigaAMTranscriber: TranscriptionProvider {
    private let plan: GigaAMConfigPlan
    private var recognizerBox: SherpaRecognizerBox?

    init(files: [ModelFileRole: URL]) throws {
        guard let plan = GigaAMConfigPlan.make(from: files) else {
            throw MacomprendoError.modelMissing("GigaAM model files")
        }
        self.plan = plan
    }

    /// GigaAM models take no language parameter: the v3 entries are Russian-only and the
    /// multilingual entries decode character-wise across their languages with no hint. The
    /// argument is accepted and ignored rather than rejected — failing a dictation over a
    /// setting the UI does not offer would be worse than simply transcribing.
    func transcribe(_ pcm: [Float], sampleRate: Int, language: String?) async throws -> String {
        guard sampleRate == 16_000 else {
            // sherpa-onnx would resample, but every other rate means the recording path is
            // wrong rather than merely unusual, so say so instead of transcribing it.
            throw MacomprendoError.audio("GigaAM requires 16 kHz mono audio, got \(sampleRate) Hz")
        }
        guard !pcm.isEmpty else { return "" }

        let recognizer = try loadedRecognizer()
        try Task.checkCancellation()

        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw MacomprendoError.audio("sherpa-onnx could not create a decoding stream")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }

        pcm.withUnsafeBufferPointer { samples in
            SherpaOnnxAcceptWaveformOffline(
                stream, Int32(sampleRate), samples.baseAddress, Int32(samples.count)
            )
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)

        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw MacomprendoError.audio("sherpa-onnx returned no result")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }

        guard let text = result.pointee.text else { return "" }
        return String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadedRecognizer() throws -> OpaquePointer {
        if let recognizerBox { return recognizerBox.pointer }

        for file in plan.requiredFiles where !FileManager.default.fileExists(atPath: file.path) {
            throw MacomprendoError.modelMissing(file.lastPathComponent)
        }

        let pointer = try makeRecognizer()
        Log.providers.info(
            "Loaded GigaAM model \(self.plan.identifyingFile.lastPathComponent, privacy: .public)"
        )

        let box = SherpaRecognizerBox(pointer: pointer)
        recognizerBox = box
        return box.pointer
    }

    /// Fills a zero-initialised config and hands it to sherpa. The C struct borrows every path
    /// pointer for the duration of the call, so each `withCString` scope must still be open
    /// when `SherpaOnnxCreateOfflineRecognizer` runs — hence the nesting rather than an array
    /// of pointers built up and released beforehand.
    ///
    /// `feat_config.feature_dim` is deliberately left at zero: sherpa recognises a GigaAM graph
    /// from its ONNX metadata and forces the 64 mel bins and the window settings GigaAM's own
    /// preprocessing uses, overriding whatever is passed in.
    private func makeRecognizer() throws -> OpaquePointer {
        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = 16_000
        // Leave two cores for the UI and the audio thread, as WhisperParams does.
        config.model_config.num_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        config.model_config.debug = 0

        let paths = plan.requiredFiles.map(\.path)
        let created = Self.withCStrings(paths) { pointers -> OpaquePointer? in
            // `requiredFiles` yields the model files in this order and tokens last.
            switch plan {
            case .ctc:
                config.model_config.nemo_ctc.model = pointers[0]
            case .transducer:
                config.model_config.transducer.encoder = pointers[0]
                config.model_config.transducer.decoder = pointers[1]
                config.model_config.transducer.joiner = pointers[2]
            }
            config.model_config.tokens = pointers[pointers.count - 1]
            return "cpu".withCString { provider -> OpaquePointer? in
                config.model_config.provider = provider
                return "greedy_search".withCString { method -> OpaquePointer? in
                    config.decoding_method = method
                    return SherpaOnnxCreateOfflineRecognizer(&config)
                }
            }
        }

        guard let created else {
            throw MacomprendoError.modelMissing(plan.identifyingFile.lastPathComponent)
        }
        return created
    }

    /// Bridges every string to a C string whose lifetime spans `body`, by nesting
    /// `withCString` one level per element.
    private static func withCStrings<R>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>]) -> R
    ) -> R {
        func step(_ index: Int, _ collected: [UnsafePointer<CChar>]) -> R {
            guard index < strings.count else { return body(collected) }
            return strings[index].withCString { pointer in
                step(index + 1, collected + [pointer])
            }
        }
        return step(0, [])
    }
}
