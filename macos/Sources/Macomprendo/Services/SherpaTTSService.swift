import Foundation
import SherpaOnnxC

struct LocalSpeechAudio: Sendable, Equatable {
    let samples: [Float]
    let sampleRate: Int
}

struct LocalTTSConfiguration: Sendable, Equatable {
    let modelID: String
    let engine: LocalEngine
    let directory: URL
    let speakerID: Int
    let speed: Float
}

protocol LocalSpeechGenerating: Sendable {
    func generate(_ text: String, configuration: LocalTTSConfiguration) async throws -> LocalSpeechAudio
}

enum SherpaTTSModelPlan: Sendable, Equatable {
    case vits(model: URL, tokens: URL, dataDirectory: URL)
    case kokoro(model: URL, voices: URL, tokens: URL, dataDirectory: URL,
                lexicons: [URL], ruleFSTs: [URL])

    static func make(modelID: String, engine: LocalEngine, directory: URL) throws -> SherpaTTSModelPlan {
        switch engine {
        case .sherpaVits:
            let prefix = "vits-piper-"
            guard modelID.hasPrefix(prefix), modelID.count > prefix.count else {
                throw MacomprendoError.modelMissing(modelID)
            }
            return .vits(
                model: directory.appendingPathComponent("\(modelID.dropFirst(prefix.count)).onnx"),
                tokens: directory.appendingPathComponent("tokens.txt"),
                dataDirectory: directory.appendingPathComponent("espeak-ng-data", isDirectory: true)
            )
        case .sherpaKokoro:
            return .kokoro(
                model: directory.appendingPathComponent("model.onnx"),
                voices: directory.appendingPathComponent("voices.bin"),
                tokens: directory.appendingPathComponent("tokens.txt"),
                dataDirectory: directory.appendingPathComponent("espeak-ng-data", isDirectory: true),
                lexicons: [
                    directory.appendingPathComponent("lexicon-us-en.txt"),
                    directory.appendingPathComponent("lexicon-zh.txt"),
                ],
                ruleFSTs: [
                    directory.appendingPathComponent("phone-zh.fst"),
                    directory.appendingPathComponent("date-zh.fst"),
                    directory.appendingPathComponent("number-zh.fst"),
                ]
            )
        case .whisperCpp, .gigaAM:
            throw MacomprendoError.modelMissing(modelID)
        }
    }

    var requiredFiles: [URL] {
        switch self {
        case .vits(let model, let tokens, let dataDirectory):
            [model, tokens, dataDirectory]
        case .kokoro(let model, let voices, let tokens, let dataDirectory, let lexicons, let ruleFSTs):
            [model, voices, tokens, dataDirectory] + lexicons + ruleFSTs
        }
    }

}

struct SherpaTTSModelIdentity: Sendable, Equatable {
    let modelID: String
    let engine: LocalEngine
    let plan: SherpaTTSModelPlan

    init(configuration: LocalTTSConfiguration) throws {
        modelID = configuration.modelID
        engine = configuration.engine
        plan = try SherpaTTSModelPlan.make(
            modelID: configuration.modelID,
            engine: configuration.engine,
            directory: configuration.directory
        )
    }
}

protocol LoadedSherpaTTSModel: Sendable {
    func generate(text: String, speakerID: Int, speed: Float) throws -> LocalSpeechAudio
}

protocol SherpaTTSBackend: Sendable {
    func load(_ identity: SherpaTTSModelIdentity) throws -> any LoadedSherpaTTSModel
}

actor SherpaSpeechGenerator: LocalSpeechGenerating {
    private let backend: any SherpaTTSBackend
    private var cachedIdentity: SherpaTTSModelIdentity?
    private var cachedModel: (any LoadedSherpaTTSModel)?

    init(backend: any SherpaTTSBackend = LiveSherpaTTSBackend()) {
        self.backend = backend
    }

    func generate(_ text: String, configuration: LocalTTSConfiguration) async throws -> LocalSpeechAudio {
        try Task.checkCancellation()
        let identity = try SherpaTTSModelIdentity(configuration: configuration)
        let model: any LoadedSherpaTTSModel
        if cachedIdentity == identity, let cachedModel {
            model = cachedModel
        } else {
            model = try backend.load(identity)
            cachedIdentity = identity
            cachedModel = model
        }

        let audio = try model.generate(
            text: text,
            speakerID: configuration.speakerID,
            speed: configuration.speed
        )
        try Task.checkCancellation()
        return audio
    }
}

struct LiveSherpaTTSBackend: SherpaTTSBackend {
    func load(_ identity: SherpaTTSModelIdentity) throws -> any LoadedSherpaTTSModel {
        for url in identity.plan.requiredFiles where !FileManager.default.fileExists(atPath: url.path) {
            throw MacomprendoError.modelMissing(identity.modelID)
        }

        let pointer = try makeTTS(for: identity)
        Log.providers.info("Loaded local TTS model \(identity.modelID, privacy: .public)")
        return LiveLoadedSherpaTTS(handle: SherpaTTSHandleBox(pointer: pointer), modelID: identity.modelID)
    }

    private func makeTTS(for identity: SherpaTTSModelIdentity) throws -> OpaquePointer {
        var config = SherpaOnnxOfflineTtsConfig()
        config.model.num_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 2))
        config.model.debug = 0
        config.max_num_sentences = 1
        config.silence_scale = 0.2

        let created: OpaquePointer?
        switch identity.plan {
        case .vits(let model, let tokens, let dataDirectory):
            created = Self.withCStrings([model.path, tokens.path, dataDirectory.path]) { pointers in
                config.model.vits.model = pointers[0]
                config.model.vits.tokens = pointers[1]
                config.model.vits.data_dir = pointers[2]
                config.model.vits.noise_scale = 0.667
                config.model.vits.noise_scale_w = 0.8
                config.model.vits.length_scale = 1
                return "cpu".withCString { provider in
                    config.model.provider = provider
                    return SherpaOnnxCreateOfflineTts(&config)
                }
            }
        case .kokoro(let model, let voices, let tokens, let dataDirectory, let lexicons, let ruleFSTs):
            let lexiconList = lexicons.map(\.path).joined(separator: ",")
            let ruleList = ruleFSTs.map(\.path).joined(separator: ",")
            created = Self.withCStrings(
                [model.path, voices.path, tokens.path, dataDirectory.path, lexiconList, ruleList]
            ) { pointers in
                config.model.kokoro.model = pointers[0]
                config.model.kokoro.voices = pointers[1]
                config.model.kokoro.tokens = pointers[2]
                config.model.kokoro.data_dir = pointers[3]
                config.model.kokoro.lexicon = pointers[4]
                config.model.kokoro.length_scale = 1
                config.rule_fsts = pointers[5]
                return "cpu".withCString { provider in
                    config.model.provider = provider
                    return SherpaOnnxCreateOfflineTts(&config)
                }
            }
        }

        guard let created else {
            throw MacomprendoError.modelMissing(identity.modelID)
        }
        return created
    }

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

private final class SherpaTTSHandleBox: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        SherpaOnnxDestroyOfflineTts(pointer)
    }
}

private final class LiveLoadedSherpaTTS: LoadedSherpaTTSModel, @unchecked Sendable {
    private let handle: SherpaTTSHandleBox
    private let modelID: String

    init(handle: SherpaTTSHandleBox, modelID: String) {
        self.handle = handle
        self.modelID = modelID
    }

    func generate(text: String, speakerID: Int, speed: Float) throws -> LocalSpeechAudio {
        guard speakerID >= 0, speakerID <= Int(Int32.max) else {
            throw MacomprendoError.modelMissing(modelID)
        }
        guard speed.isFinite, speed > 0 else {
            throw MacomprendoError.modelMissing(modelID)
        }

        var config = SherpaOnnxGenerationConfig()
        config.sid = Int32(speakerID)
        config.speed = speed
        config.silence_scale = 0.2
        let generated = text.withCString {
            SherpaOnnxOfflineTtsGenerateWithConfig(handle.pointer, $0, &config, nil, nil)
        }
        guard let generated else {
            throw MacomprendoError.modelMissing(modelID)
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(generated) }

        let count = Int(generated.pointee.n)
        let sampleRate = Int(generated.pointee.sample_rate)
        guard count > 0, sampleRate > 0, let samples = generated.pointee.samples else {
            throw MacomprendoError.modelMissing(modelID)
        }
        return LocalSpeechAudio(
            samples: Array(UnsafeBufferPointer(start: samples, count: count)),
            sampleRate: sampleRate
        )
    }
}
