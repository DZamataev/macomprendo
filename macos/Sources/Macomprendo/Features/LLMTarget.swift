import Foundation

/// A provider plus the model name to call on it.
struct LLMTarget: Sendable {
    let provider: any LLMProvider
    let model: String
}

enum FeatureConfigError: Error, LocalizedError, Equatable, Sendable {
    case llmNotConfigured(PresetKind)
    case noPreset(PresetKind)

    var errorDescription: String? {
        switch self {
        case .llmNotConfigured(let kind): "No endpoint and model chosen for \(kind.displayName)."
        case .noPreset(let kind): "No \(kind.displayName) preset is available."
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .llmNotConfigured: "Pick an endpoint and a model in Settings ▸ Refine & Summarize."
        case .noPreset: "Add a preset in Settings ▸ Refine & Summarize, or restore the factory presets."
        }
    }
}
