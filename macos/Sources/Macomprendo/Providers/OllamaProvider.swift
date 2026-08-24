import Foundation

/// Talks to Ollama's native API (`http://localhost:11434` by default, no auth).
///
/// The native API is preferred over Ollama's OpenAI compatibility shim because only
/// it exposes `/api/tags` (installed models) and `/api/pull` (one-click model install).
struct OllamaProvider: LLMProvider {
    let endpoint: Endpoint
    private let http: any HTTPClient

    init(endpoint: Endpoint, http: any HTTPClient) {
        self.endpoint = endpoint
        self.http = http
    }

    // MARK: - listModels

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    func listModels() async throws -> [String] {
        let request = HTTPRequest(
            method: "GET",
            url: EndpointURL.join(endpoint.baseURL, "/api/tags"),
            timeout: 10
        )
        let response = try await http.send(request)
        guard let decoded = try? JSONDecoder().decode(TagsResponse.self, from: response.body) else {
            throw MacomprendoError.providerStreamMalformed
        }
        return decoded.models.map(\.name)
    }

    // MARK: - chat

    private struct ChatRequestBody: Encodable {
        struct Options: Encodable {
            let temperature: Double
            let numPredict: Int?

            enum CodingKeys: String, CodingKey {
                case temperature
                case numPredict = "num_predict"
            }
        }
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let options: Options
    }

    private struct ChatChunk: Decodable {
        struct Message: Decodable { let role: String?; let content: String? }
        let message: Message?
        let done: Bool?
    }

    func chat(
        _ messages: [ChatMessage],
        model: String,
        options: ChatOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // `numPredict` nil is omitted from the JSON by the synthesised
                    // `encodeIfPresent`, so Ollama falls back to its own default.
                    let body = try JSONEncoder().encode(ChatRequestBody(
                        model: model,
                        messages: messages,
                        stream: true,
                        options: .init(temperature: options.temperature, numPredict: options.maxTokens)
                    ))
                    let request = HTTPRequest(
                        method: "POST",
                        url: EndpointURL.join(endpoint.baseURL, "/api/chat"),
                        headers: ["Content-Type": "application/json"],
                        body: body,
                        timeout: 60
                    )

                    var parser = NDJSONParser()
                    for try await bytes in http.stream(request) {
                        for document in parser.feed(bytes) {
                            if try emit(document, to: continuation) {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    for document in parser.finish() {
                        if try emit(document, to: continuation) { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decodes one NDJSON document, yields its delta, and reports whether the
    /// stream is finished (`"done": true`).
    private func emit(
        _ document: Data,
        to continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: document) else {
            throw MacomprendoError.providerStreamMalformed
        }
        if let text = chunk.message?.content, !text.isEmpty {
            continuation.yield(text)
        }
        return chunk.done == true
    }
}

/// One progress line from `POST /api/pull`. `completed`/`total` are absent on
/// status-only lines ("pulling manifest", "verifying sha256 digest", "success").
struct PullProgress: Sendable, Equatable {
    var status: String
    var completed: Int64?
    var total: Int64?

    init(status: String, completed: Int64? = nil, total: Int64? = nil) {
        self.status = status
        self.completed = completed
        self.total = total
    }
}

extension OllamaProvider {

    private struct PullRequestBody: Encodable {
        let name: String
        let stream: Bool
    }

    private struct PullChunk: Decodable {
        let status: String?
        let completed: Int64?
        let total: Int64?
    }

    /// Downloads `model` into the local Ollama instance, reporting progress.
    /// The stream ends when the HTTP body ends — there is no `done` flag; the last
    /// line is normally `{"status":"success"}`.
    func pull(model: String) -> AsyncThrowingStream<PullProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = try JSONEncoder().encode(PullRequestBody(name: model, stream: true))
                    let request = HTTPRequest(
                        method: "POST",
                        url: EndpointURL.join(endpoint.baseURL, "/api/pull"),
                        headers: ["Content-Type": "application/json"],
                        body: body,
                        timeout: 60
                    )

                    var parser = NDJSONParser()
                    for try await bytes in http.stream(request) {
                        for document in parser.feed(bytes) {
                            continuation.yield(try Self.progress(from: document))
                        }
                    }
                    for document in parser.finish() {
                        continuation.yield(try Self.progress(from: document))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func progress(from document: Data) throws -> PullProgress {
        guard let chunk = try? JSONDecoder().decode(PullChunk.self, from: document),
              let status = chunk.status else {
            throw MacomprendoError.providerStreamMalformed
        }
        return PullProgress(status: status, completed: chunk.completed, total: chunk.total)
    }
}
