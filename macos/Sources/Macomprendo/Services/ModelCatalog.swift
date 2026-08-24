import Foundation

/// One downloadable whisper.cpp ggml model.
struct WhisperModel: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let fileName: String
    /// Approximate, for pre-download UI only. The authoritative size is the
    /// `Content-Length` that `WhisperModelManager` reads with a HEAD request.
    let sizeBytes: Int64
    /// Lowercase hex digest, or `""` when not yet recorded. An empty value makes
    /// verification soft-fail with a logged warning.
    let sha256: String
    let downloadURL: URL
}

/// The models Macomprendo offers, hosted in the Hugging Face repo
/// `ggerganov/whisper.cpp`. The `.en` variants are English-only: faster and slightly
/// more accurate for English, useless for anything else.
///
/// IMPORTANT: the `WhisperModel(...)` literals below are rewritten in place by
/// `scripts/fetch-model-hashes.mjs`. Keep each on ONE line and write `sizeBytes`
/// as plain digits with no `_` separators, or the rewrite will fail.
enum ModelCatalog {

    static let defaultID = "large-v3-turbo"
    static let lightweightID = "base"

    static let all: [WhisperModel] = [
        WhisperModel(id: "tiny", displayName: "Tiny (multilingual)", fileName: "ggml-tiny.bin", sizeBytes: 77691713, sha256: "", downloadURL: downloadURL(for: "tiny")),
        WhisperModel(id: "tiny.en", displayName: "Tiny (English)", fileName: "ggml-tiny.en.bin", sizeBytes: 77704715, sha256: "", downloadURL: downloadURL(for: "tiny.en")),
        WhisperModel(id: "base", displayName: "Base (multilingual)", fileName: "ggml-base.bin", sizeBytes: 147951465, sha256: "", downloadURL: downloadURL(for: "base")),
        WhisperModel(id: "base.en", displayName: "Base (English)", fileName: "ggml-base.en.bin", sizeBytes: 147964211, sha256: "", downloadURL: downloadURL(for: "base.en")),
        WhisperModel(id: "small", displayName: "Small (multilingual)", fileName: "ggml-small.bin", sizeBytes: 487601967, sha256: "", downloadURL: downloadURL(for: "small")),
        WhisperModel(id: "small.en", displayName: "Small (English)", fileName: "ggml-small.en.bin", sizeBytes: 487614201, sha256: "", downloadURL: downloadURL(for: "small.en")),
        WhisperModel(id: "medium", displayName: "Medium (multilingual)", fileName: "ggml-medium.bin", sizeBytes: 1533763059, sha256: "", downloadURL: downloadURL(for: "medium")),
        WhisperModel(id: "medium.en", displayName: "Medium (English)", fileName: "ggml-medium.en.bin", sizeBytes: 1533774781, sha256: "", downloadURL: downloadURL(for: "medium.en")),
        WhisperModel(id: "large-v3-turbo", displayName: "Large v3 Turbo", fileName: "ggml-large-v3-turbo.bin", sizeBytes: 1624555275, sha256: "", downloadURL: downloadURL(for: "large-v3-turbo"))
    ]

    static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    private static func downloadURL(for id: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")!
    }
}
