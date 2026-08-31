import Foundation

/// Which local runtime opens a model.
enum ASREngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp
    case gigaAM
}

/// The part a file plays in a model. A whisper model is one `.ggml`; a sherpa CTC model is
/// `.ctcModel` + `.tokens`; a sherpa transducer is `.encoder` + `.decoder` + `.joiner` + `.tokens`.
enum ModelFileRole: String, Sendable, CaseIterable {
    case ggml
    case ctcModel
    case encoder
    case decoder
    case joiner
    case tokens
}

/// One file belonging to a model.
struct ModelFile: Sendable, Equatable {
    let role: ModelFileRole
    /// The name this file is stored under in the models directory. Chosen here, NOT derived
    /// from `downloadURL`: several upstream repositories publish unrelated models under the
    /// identical basenames `model.int8.onnx` and `tokens.txt`.
    let fileName: String
    /// Approximate, for pre-download UI only. The authoritative size is the `Content-Length`
    /// that `LocalModelManager` reads with a HEAD request.
    let sizeBytes: Int64
    /// Lowercase hex digest, or `""` when not yet recorded. An empty value makes verification
    /// soft-fail with a logged warning.
    let sha256: String
    let downloadURL: URL
}

/// A published measurement, quoted rather than measured by this app.
struct Benchmark: Sendable, Equatable {
    let language: String
    let dataset: String
    /// e.g. "WER %" — lower is better.
    let metric: String
    let value: Double
    /// Published numbers for other models on the same row, for context.
    let comparedTo: [String: Double]
}

/// What the Dictation tab tells the user about a model.
struct ModelBrief: Sendable, Equatable {
    let summary: String
    let strengths: [String]
    let limitations: [String]
    let benchmarks: [Benchmark]
    /// Where the numbers come from. Rendered as a link so they can be re-checked.
    let sourceURL: URL
}

/// One downloadable local ASR model.
struct LocalASRModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: ASREngine
    /// `nil` means multilingual with no published list (whisper). A non-nil list is the set of
    /// languages the publisher reports ASR quality for.
    let languages: [String]?
    let files: [ModelFile]
    let brief: ModelBrief

    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }

    func file(_ role: ModelFileRole) -> ModelFile? { files.first { $0.role == role } }
}

/// The models Macomprendo offers.
///
/// IMPORTANT: the `ModelFile(...)` literals below are rewritten in place by
/// `scripts/fetch-model-hashes.mjs`. Keep each on ONE line and write `sizeBytes` as plain
/// digits with no `_` separators, or the rewrite will fail.
enum ModelCatalog {

    static let defaultID = "large-v3-turbo"
    static let lightweightID = "base"

    static let all: [LocalASRModel] = whisper

    static func model(id: String) -> LocalASRModel? {
        all.first { $0.id == id }
    }

    static func all(for engine: ASREngine) -> [LocalASRModel] {
        all.filter { $0.engine == engine }
    }

    // MARK: - whisper.cpp

    private static let whisperSource = URL(string: "https://github.com/openai/whisper#available-models-and-languages")!

    private static let whisper: [LocalASRModel] = [
        whisperModel("tiny", "Tiny (multilingual)", 77691713, multilingual: true),
        whisperModel("tiny.en", "Tiny (English)", 77704715, multilingual: false),
        whisperModel("base", "Base (multilingual)", 147951465, multilingual: true),
        whisperModel("base.en", "Base (English)", 147964211, multilingual: false),
        whisperModel("small", "Small (multilingual)", 487601967, multilingual: true),
        whisperModel("small.en", "Small (English)", 487614201, multilingual: false),
        whisperModel("medium", "Medium (multilingual)", 1533763059, multilingual: true),
        whisperModel("medium.en", "Medium (English)", 1533774781, multilingual: false),
        whisperModel("large-v3-turbo", "Large v3 Turbo", 1624555275, multilingual: true)
    ]

    private static func whisperModel(
        _ id: String,
        _ displayName: String,
        _ sizeBytes: Int64,
        multilingual: Bool
    ) -> LocalASRModel {
        LocalASRModel(
            id: id,
            displayName: displayName,
            engine: .whisperCpp,
            languages: multilingual ? nil : ["en"],
            files: [
                ModelFile(role: .ggml, fileName: "ggml-\(id).bin", sizeBytes: sizeBytes, sha256: "", downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")!)
            ],
            brief: ModelBrief(
                summary: multilingual
                    ? "OpenAI's Whisper, running locally. Handles 90+ languages and detects the spoken language on its own."
                    : "English-only Whisper. Faster and slightly more accurate than the multilingual build of the same size, and useless for anything else.",
                strengths: multilingual
                    ? ["Broad language coverage", "Automatic language detection", "Punctuation and casing"]
                    : ["Fastest option for English", "Punctuation and casing"],
                limitations: multilingual
                    ? ["Larger models are slow on CPU", "Weaker on Russian than the GigaAM models"]
                    : ["English only — other languages are transcribed as nonsense"],
                benchmarks: [],
                sourceURL: whisperSource
            )
        )
    }
}
