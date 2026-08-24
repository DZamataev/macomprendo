import Foundation

/// Chat roles, matching the wire vocabulary shared by Ollama and OpenAI.
enum ChatRole: String, Codable, Sendable {
    case system, user, assistant
}

/// One chat turn. The `Codable` representation (`{"role":…,"content":…}`) is exactly
/// what both `/api/chat` and `/v1/chat/completions` expect, so providers encode
/// `[ChatMessage]` directly with no mapping layer.
struct ChatMessage: Codable, Sendable, Equatable {
    var role: ChatRole
    var content: String

    init(role: ChatRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// Generation knobs shared by all LLM providers.
struct ChatOptions: Sendable, Equatable {
    var temperature: Double
    var maxTokens: Int?

    init(temperature: Double = 0.3, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    static let `default` = ChatOptions()
}

/// A chat-completions backend. `chat` yields **text deltas**, not cumulative text:
/// callers append each element to what they already have.
protocol LLMProvider: Sendable {
    var endpoint: Endpoint { get }
    func listModels() async throws -> [String]
    func chat(_ messages: [ChatMessage], model: String, options: ChatOptions) -> AsyncThrowingStream<String, Error>
}
