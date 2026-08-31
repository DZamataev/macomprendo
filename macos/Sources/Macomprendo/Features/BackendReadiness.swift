import Foundation

/// What the user should do about a backend that cannot run.
enum FixAction: Sendable, Equatable {
    case download(modelID: String)
    case testEndpoint(id: UUID)
    case selectModel
}

/// The outcome of the last endpoint probe in this session.
enum EndpointProbeResult: Sendable, Equatable {
    case succeeded
    case failed(String)
}

/// Whether the configured transcription backend can actually run right now. Computed on
/// demand, never stored: it is a view of state that already exists elsewhere.
enum BackendReadiness: Sendable, Equatable {
    case ready
    case notReady(reason: String, fix: FixAction?)

    static func of(
        source: TranscriptionSource,
        states: [String: ModelState],
        endpointProbe: EndpointProbeResult?
    ) -> BackendReadiness {
        switch source {
        case .local(let modelID):
            switch states[modelID] ?? .notDownloaded {
            case .downloaded:
                return .ready
            case .notDownloaded:
                return .notReady(reason: "This model has not been downloaded yet.",
                                 fix: .download(modelID: modelID))
            case .downloading(let fraction):
                return .notReady(reason: "Downloading… \(Int(fraction * 100))%", fix: nil)
            case .failed(let message):
                return .notReady(reason: message, fix: .download(modelID: modelID))
            }

        case .endpoint(let id, let model):
            // Checked before the probe: a probe can only have succeeded against some model
            // name, and a blank one would send an unusable request at hotkey-press time.
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .notReady(reason: "No model name is set.", fix: .selectModel)
            }
            switch endpointProbe {
            case .succeeded:
                return .ready
            case .failed(let message):
                return .notReady(reason: message, fix: .testEndpoint(id: id))
            case nil:
                return .notReady(reason: "This endpoint has not been tested yet.",
                                 fix: .testEndpoint(id: id))
            }
        }
    }
}
