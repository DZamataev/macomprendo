import Foundation

enum DictationHistoryKind: String, Codable, Sendable, Equatable {
    case dictation
    case dictationAndRefine
}

/// What produced a transcript, captured at the moment the text was inserted. Built at the
/// call site, which already holds the settings snapshot that chose the provider, so neither
/// the store nor the controllers gain a dependency on `ModelCatalog`.
struct TranscriptionRun: Sendable, Equatable {
    /// The catalog id of a local model, or the endpoint's configured model name.
    let modelID: String?
    /// `whisperCpp`, the sherpa offline engine's raw value, or `endpoint`. A string rather
    /// than an enum because the corpus records what actually ran: rows written before
    /// ADR-0014's rename read `gigaAM`, and readers must accept both.
    let engine: String?
    /// The requested language setting. `nil` means automatic detection, and must stay `nil`
    /// rather than becoming an empty string.
    let language: String?
    /// `CFBundleShortVersionString` of the build that produced the text.
    let appVersion: String

    init(modelID: String?, engine: String?, language: String?, appVersion: String) {
        self.modelID = modelID
        self.engine = engine
        self.language = language
        self.appVersion = appVersion
    }
}

struct DictationHistoryEntry: Identifiable, Sendable, Equatable {
    let id: Int64
    let createdAt: Date
    let kind: DictationHistoryKind
    /// What was pasted. Once glossary normalisation exists this is the corrected string.
    let text: String
    /// The name of this entry's recording inside the store's audio directory. `nil` means no
    /// recording was ever saved; a name whose file is gone is a normal state, not corruption.
    let audioFileName: String?
    /// The model's own output, before normalisation rewrote it. `nil` means the text was not
    /// rewritten, which today is every row.
    let rawText: String?
    let modelID: String?
    let engine: String?
    let language: String?
    let appVersion: String?

    init(id: Int64, createdAt: Date, kind: DictationHistoryKind, text: String,
         audioFileName: String? = nil,
         rawText: String? = nil,
         modelID: String? = nil,
         engine: String? = nil,
         language: String? = nil,
         appVersion: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.audioFileName = audioFileName
        self.rawText = rawText
        self.modelID = modelID
        self.engine = engine
        self.language = language
        self.appVersion = appVersion
    }
}

struct DictationHistoryPage: Sendable, Equatable {
    let entries: [DictationHistoryEntry]
    let nextCursor: Int64?
}
