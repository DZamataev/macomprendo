import Foundation

/// Whether a model transcribes speech or produces it.
enum ModelKind: String, Sendable, CaseIterable { case asr, tts }

/// Which local runtime opens a model. Named for the runtime, not for the task, because one
/// runtime (sherpa-onnx) serves both kinds.
enum LocalEngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp
    case gigaAM

    var kind: ModelKind {
        switch self {
        case .whisperCpp, .gigaAM: .asr
        }
    }
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

/// One downloadable local model.
struct LocalModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let engine: LocalEngine
    /// `nil` means multilingual with no published list (whisper). A non-nil list is the set of
    /// languages the publisher reports ASR quality for.
    let languages: [String]?
    let files: [ModelFile]
    let brief: ModelBrief
    /// How many speakers the model exposes; 1 for the single-speaker Piper voices and for
    /// every ASR entry, which has no such concept. The Local tab offers a speaker picker
    /// only above 1.
    let speakerCount: Int
    /// For a model downloaded as an archive: the path inside the unpacked directory that
    /// proves the unpack succeeded. `nil` for a model stored as loose files.
    let archiveSentinel: String?

    init(id: String,
         displayName: String,
         engine: LocalEngine,
         languages: [String]?,
         files: [ModelFile],
         brief: ModelBrief,
         speakerCount: Int = 1,
         archiveSentinel: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.languages = languages
        self.files = files
        self.brief = brief
        self.speakerCount = speakerCount
        self.archiveSentinel = archiveSentinel
    }

    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    var kind: ModelKind { engine.kind }

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

    static let all: [LocalModel] = whisper + gigaAM

    static func model(id: String) -> LocalModel? {
        all.first { $0.id == id }
    }

    static func all(for engine: LocalEngine) -> [LocalModel] {
        all.filter { $0.engine == engine }
    }

    static func all(kind: ModelKind) -> [LocalModel] {
        all.filter { $0.kind == kind }
    }

    // MARK: - whisper.cpp

    private static let whisperSource = URL(string: "https://github.com/openai/whisper#available-models-and-languages")!

    private static let whisper: [LocalModel] = [
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
    ) -> LocalModel {
        LocalModel(
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

    // MARK: - GigaAM

    private static let gigaAMSource = URL(string: "https://github.com/salute-developers/GigaAM")!
    private static let gigaAMMultilingualSource = URL(string: "https://huggingface.co/ai-sage/GigaAM-Multilingual")!

    private static let v3CTCBase = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-ctc-punct-giga-am-v3-russian-2025-12-16/resolve/main"
    private static let v3RNNTBase = "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main"
    private static let multilingualBase = "https://huggingface.co/iaa2005/GigaAM-Multilingual-sherpa-onnx-ctc/resolve/main"

    private static let gigaAM: [LocalModel] = [
        LocalModel(
            id: "gigaam-v3-e2e-ctc",
            displayName: "GigaAM v3 e2e CTC (Russian)",
            engine: .gigaAM,
            languages: ["ru"],
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-v3-e2e-ctc-model.onnx", sizeBytes: 224893661, sha256: "d5fea8df94263c285e54b21e5774b707c707192d3bdbeffd7b1eb07fb6743b35", downloadURL: URL(string: "\(v3CTCBase)/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-ctc-tokens.txt", sizeBytes: 2007, sha256: "142de7570b3de5b3035ce111a89c228e80e6085273731d944093ddf24fa539cd", downloadURL: URL(string: "\(v3CTCBase)/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "Sber's GigaAM v3, fine-tuned end-to-end so it writes punctuation and normalises numbers while it transcribes. The fastest GigaAM option and the best default for Russian dictation.",
                strengths: ["Punctuation, capitalisation and spelled-out numbers", "About a seventh the size of Whisper Large v3 Turbo", "Fast on CPU"],
                limitations: ["Russian only — other languages come out as nonsense", "Slightly less accurate than the transducer below"],
                benchmarks: [],
                sourceURL: gigaAMSource
            )
        ),
        LocalModel(
            id: "gigaam-v3-e2e-rnnt",
            displayName: "GigaAM v3 e2e RNN-T (Russian)",
            engine: .gigaAM,
            languages: ["ru"],
            files: [
                ModelFile(role: .encoder, fileName: "gigaam-v3-e2e-rnnt-encoder.onnx", sizeBytes: 224570820, sha256: "369f35a71bf288d3b8e0391fabd8dba5f2314088d440bca474056b7b4b6e66bf", downloadURL: URL(string: "\(v3RNNTBase)/encoder.int8.onnx")!),
                ModelFile(role: .decoder, fileName: "gigaam-v3-e2e-rnnt-decoder.onnx", sizeBytes: 4600132, sha256: "38fc7475443ea2a26f63211ca350f73ac50fff824ab7a3876ee2bd610c53bbc4", downloadURL: URL(string: "\(v3RNNTBase)/decoder.onnx")!),
                ModelFile(role: .joiner, fileName: "gigaam-v3-e2e-rnnt-joiner.onnx", sizeBytes: 2712896, sha256: "602ff7017a93311aad34df1437c8d7f49911353c13d6eae7a6ee7b041339465c", downloadURL: URL(string: "\(v3RNNTBase)/joiner.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-v3-e2e-rnnt-tokens.txt", sizeBytes: 13354, sha256: "39abae20e692998290c574e606f11a9edef2902a1995463fcff63d1490cf22b7", downloadURL: URL(string: "\(v3RNNTBase)/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "The transducer sibling of the model above: the most accurate Russian option here, also with punctuation and normalisation built in.",
                strengths: ["Best Russian accuracy among the punctuating models", "Punctuation, capitalisation and spelled-out numbers"],
                limitations: ["Russian only", "Four files to download", "Slower than the CTC model"],
                benchmarks: [],
                sourceURL: gigaAMSource
            )
        ),
        LocalModel(
            id: "gigaam-multilingual-ctc",
            displayName: "GigaAM Multilingual CTC",
            engine: .gigaAM,
            languages: ["ru", "en", "kk", "ky", "uz"],
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-multilingual-ctc-model.onnx", sizeBytes: 224762524, sha256: "2d94f93ffd4ef58e7899c9de885c25bbbc8c9f1073618868d118a674450ba5f7", downloadURL: URL(string: "\(multilingualBase)/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-multilingual-ctc-tokens.txt", sizeBytes: 391, sha256: "9b5df7987cb4ca52c1a468649ce897fab1cd182067416e29fef49dfaa7a856c2", downloadURL: URL(string: "\(multilingualBase)/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "A 220M character-wise model covering Russian, English, Kazakh, Kyrgyz and Uzbek. Far ahead of Whisper on the Turkic languages, well behind it on English.",
                strengths: ["Five languages in one model", "Best open quality on Kazakh, Kyrgyz and Uzbek", "Same size as the Russian CTC model"],
                limitations: ["No punctuation and no capitalisation — output is one lowercase run of words", "Weaker on English than Whisper Large v3"],
                benchmarks: [
                    Benchmark(language: "ru", dataset: "Common Voice", metric: "WER %", value: 7.1, comparedTo: ["Whisper large-v3": 9.1]),
                    Benchmark(language: "en", dataset: "FLEURS", metric: "WER %", value: 12.2, comparedTo: ["Whisper large-v3": 3.9]),
                    Benchmark(language: "kk", dataset: "FLEURS", metric: "WER %", value: 5.2, comparedTo: ["Whisper large-v3": 32.4]),
                    Benchmark(language: "ky", dataset: "Common Voice", metric: "WER %", value: 12.5, comparedTo: ["Whisper large-v3": 95.2]),
                    Benchmark(language: "uz", dataset: "FLEURS", metric: "WER %", value: 10.0, comparedTo: ["Whisper large-v3": 105.4])
                ],
                sourceURL: gigaAMMultilingualSource
            )
        ),
        LocalModel(
            id: "gigaam-multilingual-large-ctc",
            displayName: "GigaAM Multilingual Large CTC",
            engine: .gigaAM,
            languages: ["ru", "en", "kk", "ky", "uz"],
            files: [
                ModelFile(role: .ctcModel, fileName: "gigaam-multilingual-large-ctc-model.onnx", sizeBytes: 591645642, sha256: "6b6f195026b0f90721cd4593c664becf009a71131550b664eec71446ec351c81", downloadURL: URL(string: "\(multilingualBase)/large/model.int8.onnx")!),
                ModelFile(role: .tokens, fileName: "gigaam-multilingual-large-ctc-tokens.txt", sizeBytes: 391, sha256: "9b5df7987cb4ca52c1a468649ce897fab1cd182067416e29fef49dfaa7a856c2", downloadURL: URL(string: "\(multilingualBase)/large/tokens.txt")!)
            ],
            brief: ModelBrief(
                summary: "The 600M version of the multilingual model, and the most accurate model offered here on Russian — at more than twice the download and noticeably more CPU per second of audio.",
                strengths: ["Best Russian accuracy of every model offered here", "Best open quality on Kazakh, Kyrgyz and Uzbek"],
                limitations: ["No punctuation and no capitalisation", "592 MB download", "Slowest option on CPU", "Still behind Whisper on English"],
                benchmarks: [
                    Benchmark(language: "ru", dataset: "Common Voice", metric: "WER %", value: 5.1, comparedTo: ["Whisper large-v3": 9.1]),
                    Benchmark(language: "ru", dataset: "FLEURS", metric: "WER %", value: 3.0, comparedTo: ["Whisper large-v3": 3.1]),
                    Benchmark(language: "en", dataset: "FLEURS", metric: "WER %", value: 9.4, comparedTo: ["Whisper large-v3": 3.9]),
                    Benchmark(language: "kk", dataset: "FLEURS", metric: "WER %", value: 4.4, comparedTo: ["Whisper large-v3": 32.4])
                ],
                sourceURL: gigaAMMultilingualSource
            )
        )
    ]
}
