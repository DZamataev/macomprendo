import Foundation

/// Talks to any server implementing OpenAI's `/v1/models` and
/// `/v1/chat/completions` — api.openai.com, Groq, Together, OpenRouter, LM Studio,
/// llama.cpp's server, and Ollama's own `/v1` compatibility shim.
///
/// The base URL is normalised by `EndpointURL.openAI`, so a user may enter
/// `https://api.openai.com` or `https://api.openai.com/v1` interchangeably.
struct OpenAICompatibleLLMProvider: LLMProvider {
    let endpoint: Endpoint
    private let apiKey: String?
    private let http: any HTTPClient

    init(endpoint: Endpoint, apiKey: String?, http: any HTTPClient) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.http = http
    }

    /// `Authorization` is omitted entirely for a nil/empty key: local servers
    /// reject a literal `Bearer ` with no token.
    private func headers(json: Bool) -> [String: String] {
        var headers: [String: String] = [:]
        if json { headers["Content-Type"] = "application/json" }
        if let apiKey, !apiKey.isEmpty { headers["Authorization"] = "Bearer \(apiKey)" }
        return headers
    }

    // MARK: - listModels

    private struct ModelsResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]
    }

    func listModels() async throws -> [String] {
        let request = HTTPRequest(
            method: "GET",
            url: EndpointURL.openAI(endpoint.baseURL, "/models"),
            headers: headers(json: false),
            timeout: 10
        )
        let response = try await http.send(request)
        guard let decoded = try? JSONDecoder().decode(ModelsResponse.self, from: response.body) else {
            throw MacomprendoError.providerStreamMalformed
        }
        return decoded.data.map(\.id)
    }

    // MARK: - chat

    private struct CompletionsBody: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let temperature: Double
        let maxTokens: Int?

        enum CodingKeys: String, CodingKey {
            case model, messages, stream, temperature
            case maxTokens = "max_tokens"
        }
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
        }
        let choices: [Choice]?
    }

    private static let doneSentinel = "[DONE]"

    func chat(
        _ messages: [ChatMessage],
        model: String,
        options: ChatOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `maxTokens` nil is omitted from the JSON by the synthesised
                    // `encodeIfPresent`; some gateways 400 on an explicit null.
                    let body = try JSONEncoder().encode(CompletionsBody(
                        model: model,
                        messages: messages,
                        stream: true,
                        temperature: options.temperature,
                        maxTokens: options.maxTokens
                    ))
                    let request = HTTPRequest(
                        method: "POST",
                        url: EndpointURL.openAI(endpoint.baseURL, "/chat/completions"),
                        headers: headers(json: true),
                        body: body,
                        timeout: 60
                    )

                    var parser = SSEParser()
                    for try await bytes in http.stream(request) {
                        for event in parser.feed(bytes) {
                            if try Self.emit(event, to: continuation) {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    for event in parser.finish() {
                        if try Self.emit(event, to: continuation) { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Yields an event's content delta. Returns `true` when the event is the
    /// `[DONE]` terminator and the stream should stop.
    private static func emit(
        _ event: SSEEvent,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        if event.data == doneSentinel { return true }
        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: Data(event.data.utf8)) else {
            throw MacomprendoError.providerStreamMalformed
        }
        if let text = chunk.choices?.first?.delta?.content, !text.isEmpty {
            continuation.yield(text)
        }
        return false
    }
}
