import Foundation

/// One of the existing user-facing actions that can be triggered by the middle mouse button.
enum MiddleMouseAction: String, CaseIterable, Codable, Sendable, Equatable {
    case dictate
    case dictateAndRefine
    case speak
    case summarize
    case refineSelection

    var displayName: String {
        switch self {
        case .dictate: "Dictate"
        case .dictateAndRefine: "Dictate & Refine"
        case .speak: "Speak selection"
        case .summarize: "Summarize selection"
        case .refineSelection: "Refine selection"
        }
    }
}
