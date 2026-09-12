import Foundation

enum DictationHistoryKind: String, Codable, Sendable, Equatable {
    case dictation
    case dictationAndRefine
}

struct DictationHistoryEntry: Identifiable, Sendable, Equatable {
    let id: Int64
    let createdAt: Date
    let kind: DictationHistoryKind
    let text: String
    /// The name of this entry's recording inside the store's audio directory. `nil` means no
    /// recording was ever saved; a name whose file is gone is a normal state, not corruption.
    let audioFileName: String?

    init(id: Int64, createdAt: Date, kind: DictationHistoryKind, text: String,
         audioFileName: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.text = text
        self.audioFileName = audioFileName
    }
}

struct DictationHistoryPage: Sendable, Equatable {
    let entries: [DictationHistoryEntry]
    let nextCursor: Int64?
}
