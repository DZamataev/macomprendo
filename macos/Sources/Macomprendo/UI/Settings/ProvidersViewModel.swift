import Foundation
import SwiftUI

/// Anything that can pull a model into a local runtime. Only Ollama endpoints can.
protocol ModelPulling: Sendable {
    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error>
}

extension OllamaProvider: ModelPulling {}

extension Endpoint {
    /// Keychain account name for an endpoint's API key. Secrets never live in `Settings`.
    static func keychainAccount(for id: UUID) -> String {
        "endpoint.\(id.uuidString)"
    }
}

@MainActor
final class ProvidersViewModel: ObservableObject {
    @Published private(set) var endpoints: [Endpoint]
    @Published private(set) var testResults: [UUID: String] = [:]
    @Published private(set) var pullStatus: String?
    @Published private(set) var pullProgress: Double?

    private(set) var testTask: Task<Void, Never>?
    private(set) var pullTask: Task<Void, Never>?

    private let update: @MainActor ([Endpoint]) -> Void
    private let keychain: any KeychainStoring
    private let llmFor: @Sendable (Endpoint) throws -> any LLMProvider
    private let pullerFor: @Sendable (Endpoint) -> (any ModelPulling)?

    init(endpoints: [Endpoint],
         update: @escaping @MainActor ([Endpoint]) -> Void,
         keychain: any KeychainStoring,
         llmFor: @escaping @Sendable (Endpoint) throws -> any LLMProvider,
         pullerFor: @escaping @Sendable (Endpoint) -> (any ModelPulling)?) {
        self.endpoints = endpoints
        self.update = update
        self.keychain = keychain
        self.llmFor = llmFor
        self.pullerFor = pullerFor
    }

    func add() {
        let endpoint = Endpoint(id: UUID(),
                                name: "New endpoint",
                                kind: .openAICompatible,
                                baseURL: URL(string: "https://api.openai.com")!,
                                apiKeyRef: nil)
        endpoints.append(endpoint)
        update(endpoints)
    }

    func update(_ endpoint: Endpoint) {
        guard let index = endpoints.firstIndex(where: { $0.id == endpoint.id }) else { return }
        endpoints[index] = endpoint
        update(endpoints)
    }

    func remove(_ id: UUID) {
        endpoints.removeAll { $0.id == id }
        try? keychain.delete(account: Endpoint.keychainAccount(for: id))
        testResults[id] = nil
        update(endpoints)
    }

    func apiKey(for endpoint: Endpoint) -> String {
        ((try? keychain.get(account: Endpoint.keychainAccount(for: endpoint.id))) ?? nil) ?? ""
    }

    func setAPIKey(_ key: String, for endpoint: Endpoint) {
        let account = Endpoint.keychainAccount(for: endpoint.id)
        var updated = endpoint
        if key.isEmpty {
            try? keychain.delete(account: account)
            updated.apiKeyRef = nil
        } else {
            try? keychain.set(key, account: account)
            updated.apiKeyRef = account
        }
        update(updated)
    }

    func testConnection(_ endpoint: Endpoint) {
        testTask?.cancel()
        testResults[endpoint.id] = "Testing…"
        testTask = Task { [weak self] in
            guard let self else { return }
            do {
                let models = try await self.llmFor(endpoint).listModels()
                self.testResults[endpoint.id] = "Connected — \(models.count) models"
            } catch {
                self.testResults[endpoint.id] = ErrorText.describe(error)
            }
        }
    }

    func pull(model: String, from endpoint: Endpoint) {
        pullTask?.cancel()
        guard let puller = pullerFor(endpoint) else {
            pullStatus = "Only Ollama endpoints can pull models."
            pullProgress = nil
            return
        }
        pullStatus = "Starting…"
        pullProgress = nil
        pullTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await progress in puller.pull(model: model) {
                    self.pullStatus = progress.status
                    if let completed = progress.completed, let total = progress.total, total > 0 {
                        self.pullProgress = Double(completed) / Double(total)
                    }
                }
                self.pullStatus = "Pulled \(model)"
            } catch {
                self.pullStatus = ErrorText.describe(error)
            }
            self.pullProgress = nil
        }
    }
}
