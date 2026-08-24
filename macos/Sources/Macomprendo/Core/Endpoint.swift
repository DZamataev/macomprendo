import Foundation

/// The API dialect an endpoint speaks.
enum EndpointKind: String, Codable, Sendable, CaseIterable {
    case ollama
    case openAICompatible
}

/// A user-configured LLM or transcription server.
struct Endpoint: Codable, Sendable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: EndpointKind
    var baseURL: URL
    /// Keychain account name holding the API key. `nil` means "no key needed".
    /// The key itself is never stored here.
    var apiKeyRef: String?

    init(id: UUID = UUID(), name: String, kind: EndpointKind, baseURL: URL, apiKeyRef: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.apiKeyRef = apiKeyRef
    }

    /// Fixed id for the seeded local Ollama endpoint, so settings migrations and
    /// `LLMSelection` defaults can refer to it without a lookup by name.
    static let ollamaLocalID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!

    static func ollamaLocal() -> Endpoint {
        Endpoint(
            id: ollamaLocalID,
            name: "Ollama (local)",
            kind: .ollama,
            baseURL: URL(string: "http://localhost:11434")!,
            apiKeyRef: nil
        )
    }
}
