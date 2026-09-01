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
}

struct DictationHistoryPage: Sendable, Equatable {
    let entries: [DictationHistoryEntry]
    let nextCursor: Int64?
}
