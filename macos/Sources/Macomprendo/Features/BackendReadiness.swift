import Foundation

/// What the user should do about a backend that cannot run.
enum FixAction: Sendable, Equatable {
    case download(modelID: String)
    case testEndpoint(EndpointProbeTarget)
    case selectModel
}

/// The exact server and model an endpoint probe exercised.
struct EndpointProbeTarget: Sendable, Equatable {
    let id: UUID
    let model: String

    var source: TranscriptionSource { .endpoint(id: id, model: model) }
}

/// The outcome of the last endpoint probe in this session. Both outcomes carry *what they
/// proved* so a verdict cannot be read as covering a server or model that was never contacted.
/// A target is absent only when configuration was incomplete and no request could be made.
enum EndpointProbeResult: Sendable, Equatable {
    case succeeded(EndpointProbeTarget)
    case failed(target: EndpointProbeTarget?, message: String)
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
            let target = EndpointProbeTarget(id: id, model: model)
            switch endpointProbe {
            case .succeeded(let probedTarget) where probedTarget == target:
                return .ready
            case .failed(let probedTarget, let message) where probedTarget == target:
                return .notReady(reason: message, fix: .testEndpoint(target))
            // A result against a different server or model proves nothing about this one, so
            // it reads exactly like never having been tested.
            case .succeeded, .failed, nil:
                return .notReady(reason: "This endpoint has not been tested yet.",
                                 fix: .testEndpoint(target))
            }
        }
    }
}
