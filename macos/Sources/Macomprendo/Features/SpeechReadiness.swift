import Foundation

/// What the user should do about a speech source that cannot speak.
enum SpeechFixAction: Sendable, Equatable {
    case downloadModel(id: String)
    case selectModel
    case fillEndpoint
    case saveKey
}

/// Whether the configured speech source can actually speak right now. Computed on demand,
/// never stored: it is a view of state that already exists elsewhere.
///
/// A sibling of `BackendReadiness` rather than a generalisation of it — that type switches on
/// `TranscriptionSource` and this one on `SpeechSource`, and a shared generic would add a type
/// parameter to save three lines.
///
/// The endpoint rule is deliberately weaker than the transcription one: it claims "configured",
/// not "verified". Proving a speech endpoint works means paying for a synthesis request and
/// making a settings screen wait for it, and a wrong key surfaces harmlessly at the first
/// hotkey press through `SpeakController`'s error toast — where a wrong transcription endpoint
/// surfaces only after the user has already spoken and lost the dictation.
enum SpeechReadiness: Sendable, Equatable {
    case ready
    case notReady(reason: String, fix: SpeechFixAction?)

    static func of(source: SpeechSource,
                   settings: SpeechSettings,
                   modelStates: [String: ModelState]) -> SpeechReadiness {
        switch source {
        case .system:
            // A nil voiceID is not a failure: AVFoundation falls back to the system default.
            return .ready

        case .local:
            guard let id = settings.localModelID else {
                return .notReady(reason: "No voice has been chosen yet.", fix: .selectModel)
            }
            switch modelStates[id] ?? .notDownloaded {
            case .downloaded:
                return .ready
            case .notDownloaded:
                return .notReady(reason: "This voice has not been downloaded yet.",
                                 fix: .downloadModel(id: id))
            case .downloading(let fraction):
                return .notReady(reason: "Downloading… \(Int(fraction * 100))%", fix: nil)
            case .failed(let message):
                return .notReady(reason: message, fix: .downloadModel(id: id))
            }

        case .endpoint:
            // Field order matters: there is one fix button, and filling the form comes before
            // saving a key for it.
            let fields = [settings.endpointBaseURL.absoluteString,
                          settings.endpointModel,
                          settings.endpointVoice]
            guard fields.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else {
                return .notReady(reason: "The server, model and voice must all be filled in.",
                                 fix: .fillEndpoint)
            }
            guard settings.endpointAPIKeyRef != nil else {
                return .notReady(reason: "No API key is saved for this server.", fix: .saveKey)
            }
            return .ready
        }
    }
}
