import Foundation

/// Maps configuration (`Endpoint`, `TranscriptionSource`) onto concrete providers,
/// and is the only place that reads API keys out of the Keychain. Controllers never
/// construct a provider directly.
struct ProviderFactory: Sendable {
    private let http: any HTTPClient
    private let keychain: any KeychainStoring

    init(http: any HTTPClient, keychain: any KeychainStoring) {
        self.http = http
        self.keychain = keychain
    }

    /// Ollama endpoints also serve `/v1/...`, but the native API is chosen for
    /// `kind == .ollama` because only it exposes `/api/tags` and `/api/pull`.
    func llm(for endpoint: Endpoint) throws -> any LLMProvider {
        switch endpoint.kind {
        case .ollama:
            return OllamaProvider(endpoint: endpoint, http: http)
        case .openAICompatible:
            return OpenAICompatibleLLMProvider(
                endpoint: endpoint,
                apiKey: apiKey(for: endpoint),
                http: http
            )
        }
    }

    /// - Note: `async` because resolving a local model has to ask the actor-isolated
    ///   `ModelManaging` where the file is.
    func transcriber(
        for source: TranscriptionSource,
        endpoints: [Endpoint],
        models: any ModelManaging
    ) async throws -> any TranscriptionProvider {
        switch source {
        case .local(let modelID):
            guard let resolved = await models.resolved(modelID) else {
                throw MacomprendoError.modelMissing(modelID)
            }
            switch resolved.engine {
            case .whisperCpp:
                guard let modelURL = resolved.files[.ggml] else {
                    throw MacomprendoError.modelMissing(modelID)
                }
                return WhisperCppTranscriber(modelURL: modelURL)
            case .gigaAM:
                return try GigaAMTranscriber(files: resolved.files)
            }

        case .endpoint(let id, let model):
            guard let endpoint = endpoints.first(where: { $0.id == id }) else {
                // The endpoint was deleted from Settings while still selected.
                throw MacomprendoError.providerUnreachable(endpointName: id.uuidString)
            }
            return OpenAICompatibleTranscriber(
                endpoint: endpoint,
                apiKey: apiKey(for: endpoint),
                model: model,
                http: http
            )
        }
    }

    /// A missing Keychain entry yields `nil` rather than an error: the request then
    /// goes out unauthenticated and the server's 401 surfaces as an actionable
    /// `providerHTTP`, which beats failing opaquely before anything is sent.
    private func apiKey(for endpoint: Endpoint) -> String? {
        guard let account = endpoint.apiKeyRef else { return nil }
        return try? keychain.get(account: account)
    }
}
