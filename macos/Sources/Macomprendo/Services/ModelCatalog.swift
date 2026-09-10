import Foundation

/// Whether a model transcribes speech or produces it.
enum ModelKind: String, Sendable, CaseIterable { case asr, tts }

/// Which local runtime opens a model. Named for the runtime, not for the task, because one
/// runtime (sherpa-onnx) serves both kinds.
enum LocalEngine: String, Codable, Sendable, CaseIterable {
    case whisperCpp
    case gigaAM
    case sherpaVits
    case sherpaKokoro

    var kind: ModelKind {
        switch self {
        case .whisperCpp, .gigaAM: .asr
        case .sherpaVits, .sherpaKokoro: .tts
        }
    }
}

/// The part a file plays in a model. ASR models are stored as loose engine files; local TTS
/// models arrive as one verified archive whose contents are opened by sherpa-onnx.
enum ModelFileRole: String, Sendable, CaseIterable {
    case ggml
    case ctcModel
    case encoder
    case decoder
    case joiner
    case tokens
    case archive
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
    /// `nil` means multilingual with no published list (Whisper). A non-nil list is the set of
    /// languages the publisher declares the ASR or TTS model supports.
    let languages: [String]?
    let files: [ModelFile]
    let brief: ModelBrief
    /// How many speakers the model exposes; 1 for the single-speaker Piper voices and for
    /// every ASR entry, which has no such concept. The Local tab offers a speaker picker
    /// only above 1.
    let speakerCount: Int
    /// Sum of extracted regular-file sizes for archive models. Download progress still uses
    /// the compressed `totalSizeBytes`.
    let installedSizeBytes: Int64?
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
         installedSizeBytes: Int64? = nil,
         archiveSentinel: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.engine = engine
        self.languages = languages
        self.files = files
        self.brief = brief
        self.speakerCount = speakerCount
        self.installedSizeBytes = installedSizeBytes
        self.archiveSentinel = archiveSentinel
    }

    var totalSizeBytes: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    var kind: ModelKind { engine.kind }

    func file(_ role: ModelFileRole) -> ModelFile? { files.first { $0.role == role } }

    /// What `languages` says, in words. `nil` means multilingual with no published list, which
    /// is whisper — not "no languages". Named in English, like the rest of the UI, rather than
    /// in the system language.
    var languagesText: String { Self.languagesText(languages) }

    /// Same wording, usable without a full `LocalModel` — `ModelBriefView` names one language
    /// per benchmark row rather than a model's whole list.
    static func languagesText(_ languages: [String]?) -> String {
        guard let languages, !languages.isEmpty else { return "90+ languages" }
        let english = Locale(identifier: "en_US")
        let names = languages.map { code in
            english.localizedString(forLanguageCode: code) ?? code
        }
        return names.joined(separator: ", ")
    }
}

/// The models Macomprendo offers.
///
/// IMPORTANT: the `ModelFile(...)` literals below are rewritten in place by
/// `scripts/fetch-model-hashes.mjs`. Keep each on ONE line and write `sizeBytes` as plain
/// digits with no `_` separators, or the rewrite will fail.
enum ModelCatalog {

    static let defaultID = "large-v3-turbo"
    static let lightweightID = "base"

    static let all: [LocalModel] = whisper + gigaAM + localTTS

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
        whisperModel("tiny", "Tiny (multilingual)", 77691713,
                     "be07e048e1e599ad46341c8d2a135645097a538221678b7acdd1b1919c6e1b21", multilingual: true),
        whisperModel("tiny.en", "Tiny (English)", 77704715,
                     "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f", multilingual: false),
        whisperModel("base", "Base (multilingual)", 147951465,
                     "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", multilingual: true),
        whisperModel("base.en", "Base (English)", 147964211,
                     "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", multilingual: false),
        whisperModel("small", "Small (multilingual)", 487601967,
                     "1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b", multilingual: true),
        whisperModel("small.en", "Small (English)", 487614201,
                     "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", multilingual: false),
        whisperModel("medium", "Medium (multilingual)", 1533763059,
                     "6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208", multilingual: true),
        whisperModel("medium.en", "Medium (English)", 1533774781,
                     "cc37e93478338ec7700281a7ac30a10128929eb8f427dda2e865faa8f6da4356", multilingual: false),
        whisperModel("large-v3-turbo", "Large v3 Turbo", 1624555275,
                     "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69", multilingual: true)
    ]

    private static func whisperModel(
        _ id: String,
        _ displayName: String,
        _ sizeBytes: Int64,
        _ sha256: String,
        multilingual: Bool
    ) -> LocalModel {
        LocalModel(
            id: id,
            displayName: displayName,
            engine: .whisperCpp,
            languages: multilingual ? nil : ["en"],
            files: [
                ModelFile(role: .ggml, fileName: "ggml-\(id).bin", sizeBytes: sizeBytes, sha256: sha256, downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")!)
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

    // MARK: - Local TTS

    private static let localTTSSource = URL(string: "https://k2-fsa.github.io/sherpa/onnx/tts/pretrained_models/index.html")!
    private static let localTTSBase = "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models"

    private static let localTTS: [LocalModel] = [
        ttsArchiveModel(
            id: "vits-piper-ru_RU-ruslan-medium",
            displayName: "Piper Ruslan (Russian)",
            summary: "A male Russian Piper voice named Ruslan with a compact 81 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["ru"],
            file: ModelFile(role: .archive, fileName: "vits-piper-ru_RU-ruslan-medium.tar.bz2", sizeBytes: 67210684, sha256: "0690b1cad01f86e8db9ba988af24898bdc1af774e23cb2e46b9c730269b6fd83", downloadURL: URL(string: "\(localTTSBase)/vits-piper-ru_RU-ruslan-medium.tar.bz2")!),
            installedSizeBytes: 81146959,
            sentinel: "ru_RU-ruslan-medium.onnx"
        ),
        ttsArchiveModel(
            id: "vits-piper-ru_RU-irina-medium",
            displayName: "Piper Irina (Russian)",
            summary: "A female Russian Piper voice with a compact 81 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["ru"],
            file: ModelFile(role: .archive, fileName: "vits-piper-ru_RU-irina-medium.tar.bz2", sizeBytes: 67153308, sha256: "1fc0f54e5e084fe287c07909f2f6e0ba6d857864cf800e3ab80286a4e8233008", downloadURL: URL(string: "\(localTTSBase)/vits-piper-ru_RU-irina-medium.tar.bz2")!),
            installedSizeBytes: 81146778,
            sentinel: "ru_RU-irina-medium.onnx"
        ),
        ttsArchiveModel(
            id: "vits-piper-ru_RU-dmitri-medium",
            displayName: "Piper Dmitri (Russian)",
            summary: "A male Russian Piper voice named Dmitri with a compact 81 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["ru"],
            file: ModelFile(role: .archive, fileName: "vits-piper-ru_RU-dmitri-medium.tar.bz2", sizeBytes: 67188551, sha256: "c86d0803737de13d441923ff3b3f309482fab8d7af3ec85949942809eb9a3660", downloadURL: URL(string: "\(localTTSBase)/vits-piper-ru_RU-dmitri-medium.tar.bz2")!),
            installedSizeBytes: 81146850,
            sentinel: "ru_RU-dmitri-medium.onnx"
        ),
        ttsArchiveModel(
            id: "vits-piper-ru_RU-denis-medium",
            displayName: "Piper Denis (Russian)",
            summary: "A male Russian Piper voice named Denis with a compact 81 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["ru"],
            file: ModelFile(role: .archive, fileName: "vits-piper-ru_RU-denis-medium.tar.bz2", sizeBytes: 67190991, sha256: "efa4c18e0b5e32b81d1b6df36b9d312831e5d545200e27848ef926a4cd930300", downloadURL: URL(string: "\(localTTSBase)/vits-piper-ru_RU-denis-medium.tar.bz2")!),
            installedSizeBytes: 81146848,
            sentinel: "ru_RU-denis-medium.onnx"
        ),
        ttsArchiveModel(
            id: "vits-piper-en_US-lessac-medium",
            displayName: "Piper Lessac (English US)",
            summary: "A male US English Piper voice with a compact 81 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["en"],
            file: ModelFile(role: .archive, fileName: "vits-piper-en_US-lessac-medium.tar.bz2", sizeBytes: 67230653, sha256: "9e3febfacf0abf4270172d2958bcec246032b7e88efc2720840cc80c93de334e", downloadURL: URL(string: "\(localTTSBase)/vits-piper-en_US-lessac-medium.tar.bz2")!),
            installedSizeBytes: 81147006,
            sentinel: "en_US-lessac-medium.onnx"
        ),
        ttsArchiveModel(
            id: "vits-piper-en_US-libritts_r-medium",
            displayName: "Piper LibriTTS-R (English US)",
            summary: "A Piper model with 904 US English speakers and a 97 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["en"],
            file: ModelFile(role: .archive, fileName: "vits-piper-en_US-libritts_r-medium.tar.bz2", sizeBytes: 82038311, sha256: "10dc268f3e371696d721486123e2705a9fc1faa113491979fde4d88dba1f1b1c", downloadURL: URL(string: "\(localTTSBase)/vits-piper-en_US-libritts_r-medium.tar.bz2")!),
            speakerCount: 904,
            installedSizeBytes: 96542847,
            sentinel: "en_US-libritts_r-medium.onnx"
        ),
        ttsArchiveModel(
            id: "vits-piper-en_GB-alba-medium",
            displayName: "Piper Alba (English UK)",
            summary: "A female British English Piper voice with a compact 81 MB installed footprint.",
            engine: .sherpaVits,
            languages: ["en"],
            file: ModelFile(role: .archive, fileName: "vits-piper-en_GB-alba-medium.tar.bz2", sizeBytes: 67212349, sha256: "fcd45962906933eec4431d3688f7d74aaac8713c87c6717f91fd3b23463aa1a1", downloadURL: URL(string: "\(localTTSBase)/vits-piper-en_GB-alba-medium.tar.bz2")!),
            installedSizeBytes: 81199214,
            sentinel: "en_GB-alba-medium.onnx"
        ),
        ttsArchiveModel(
            id: "kokoro-multi-lang-v1_1",
            displayName: "Kokoro Multi-language v1.1",
            summary: "A 427 MB Kokoro model with 103 speakers for English and Chinese.",
            engine: .sherpaKokoro,
            languages: ["en", "zh"],
            file: ModelFile(role: .archive, fileName: "kokoro-multi-lang-v1_1.tar.bz2", sizeBytes: 364816464, sha256: "a3f4c73d043860e3fd2e5b06f36795eb81de0fc8e8de6df703245edddd87dbad", downloadURL: URL(string: "\(localTTSBase)/kokoro-multi-lang-v1_1.tar.bz2")!),
            speakerCount: 103,
            installedSizeBytes: 426654376,
            sentinel: "model.onnx"
        )
    ]

    private static func ttsArchiveModel(
        id: String,
        displayName: String,
        summary: String,
        engine: LocalEngine,
        languages: [String],
        file: ModelFile,
        speakerCount: Int = 1,
        installedSizeBytes: Int64,
        sentinel: String
    ) -> LocalModel {
        let isKokoro = engine == .sherpaKokoro
        let limitations = if isKokoro {
            ["English and Chinese only; Russian is not supported",
             "Large 427 MB installed footprint", "Speaker picker uses numeric IDs"]
        } else if speakerCount > 1 {
            ["English only", "Speaker picker uses numeric IDs", "Medium-quality Piper synthesis"]
        } else {
            ["Single speaker", "Only the listed language", "Medium-quality Piper synthesis"]
        }
        return LocalModel(
            id: id,
            displayName: displayName,
            engine: engine,
            languages: languages,
            files: [file],
            brief: ModelBrief(
                summary: summary,
                strengths: isKokoro
                    ? ["103 speakers", "English and Chinese synthesis", "No speech text leaves this Mac"]
                    : ["Fast CPU synthesis", "Small local footprint", "No speech text leaves this Mac"],
                limitations: limitations,
                benchmarks: [],
                sourceURL: localTTSSource
            ),
            speakerCount: speakerCount,
            installedSizeBytes: installedSizeBytes,
            archiveSentinel: sentinel
        )
    }
}
