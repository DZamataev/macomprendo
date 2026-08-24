import Foundation
import Testing
@testable import Macomprendo

@Suite struct OpenAICompatibleLLMProviderTests {

    private func makeEndpoint(_ baseURL: String = "https://api.example.com") -> Endpoint {
        Endpoint(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Example AI",
            kind: .openAICompatible,
            baseURL: URL(string: baseURL)!,
            apiKeyRef: "example-key"
        )
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return deltas
    }

    private static let sseFixture = """
    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

    data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

    data: [DONE]

    """

    // MARK: - listModels

    @Test func listModelsReturnsEveryModelID() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"""
        {"object":"list","data":[
          {"id":"gpt-4o-mini","owned_by":"system"},
          {"id":"gpt-4o","owned_by":"system"}
        ]}
        """#.utf8))

        let models = try await OpenAICompatibleLLMProvider(
            endpoint: makeEndpoint(), apiKey: "sk-test", http: http
        ).listModels()

        #expect(models == ["gpt-4o-mini", "gpt-4o"])
        #expect(http.requests[0].url == URL(string: "https://api.example.com/v1/models")!)
        #expect(http.requests[0].headers["Authorization"] == "Bearer sk-test")
    }

    @Test func listModelsOmitsTheAuthorizationHeaderWithoutAKey() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"data":[{"id":"local-model"}]}"#.utf8))

        _ = try await OpenAICompatibleLLMProvider(
            endpoint: makeEndpoint("http://localhost:1234/v1"), apiKey: nil, http: http
        ).listModels()

        #expect(http.requests[0].headers["Authorization"] == nil)
        #expect(http.requests[0].url == URL(string: "http://localhost:1234/v1/models")!)
    }

    @Test func listModelsOmitsTheAuthorizationHeaderForAnEmptyKey() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"data":[]}"#.utf8))

        _ = try await OpenAICompatibleLLMProvider(
            endpoint: makeEndpoint(), apiKey: "", http: http
        ).listModels()

        #expect(http.requests[0].headers["Authorization"] == nil)
    }

    @Test func listModelsThrowsStreamMalformedForUnexpectedJSON() async {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"models":[]}"#.utf8))

        await #expect(throws: MacomprendoError.providerStreamMalformed) {
            _ = try await OpenAICompatibleLLMProvider(
                endpoint: makeEndpoint(), apiKey: "sk-test", http: http
            ).listModels()
        }
    }

    @Test func listModelsPropagatesA401() async {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", status: 401, body: Data(#"{"error":"invalid api key"}"#.utf8))

        await #expect(throws: MacomprendoError.providerHTTP(status: 401, body: #"{"error":"invalid api key"}"#)) {
            _ = try await OpenAICompatibleLLMProvider(
                endpoint: makeEndpoint(), apiKey: "sk-bad", http: http
            ).listModels()
        }
    }

    // MARK: - chat request shape

    @Test func chatPostsModelMessagesStreamAndTemperatureWithBearerAuth() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data("data: [DONE]\n\n".utf8)])

        _ = try await collect(
            OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk-test", http: http).chat(
                [ChatMessage(role: .system, content: "Return only the result."),
                 ChatMessage(role: .user, content: "clean up: helo")],
                model: "gpt-4o-mini",
                options: ChatOptions(temperature: 0.9)
            )
        )

        let request = http.requests(forPath: "/v1/chat/completions")[0]
        #expect(request.method == "POST")
        #expect(request.url == URL(string: "https://api.example.com/v1/chat/completions")!)
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        #expect(request.headers["Content-Type"] == "application/json")

        let requestBody = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["model"] as? String == "gpt-4o-mini")
        #expect(body["stream"] as? Bool == true)
        #expect(body["temperature"] as? Double == 0.9)
        #expect(body["max_tokens"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "Return only the result."],
            ["role": "user", "content": "clean up: helo"]
        ])
    }

    @Test func chatIncludesMaxTokensOnlyWhenSet() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data("data: [DONE]\n\n".utf8)])

        _ = try await collect(
            OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: nil, http: http).chat(
                [ChatMessage(role: .user, content: "hi")],
                model: "gpt-4o-mini",
                options: ChatOptions(temperature: 0.3, maxTokens: 512)
            )
        )

        let requestBody = try #require(http.requests(forPath: "/v1/chat/completions")[0].body)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 512)
    }

    @Test func chatNormalisesABaseURLThatAlreadyEndsInV1() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data("data: [DONE]\n\n".utf8)])

        _ = try await collect(
            OpenAICompatibleLLMProvider(
                endpoint: makeEndpoint("http://localhost:1234/v1"), apiKey: nil, http: http
            ).chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
        )

        #expect(http.requests(forPath: "/v1/chat/completions")[0].url
                == URL(string: "http://localhost:1234/v1/chat/completions")!)
    }

    // MARK: - chat streaming

    @Test func chatYieldsOnlyNonEmptyContentDeltas() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data(Self.sseFixture.utf8)])

        let deltas = try await collect(
            OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
                .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
        )

        #expect(deltas == ["Hello", " world"])
    }

    @Test func chatStopsAtTheDoneSentinelAndIgnoresAnythingAfterIt() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data("""
        data: {"choices":[{"delta":{"content":"kept"}}]}

        data: [DONE]

        data: {"choices":[{"delta":{"content":"dropped"}}]}

        """.utf8)])

        let deltas = try await collect(
            OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
                .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
        )

        #expect(deltas == ["kept"])
    }

    @Test func chatReassemblesDeltasSplitAcrossArbitraryChunkBoundaries() async throws {
        let payload = Array(Self.sseFixture.utf8)
        for cut in stride(from: 0, through: payload.count, by: 19) {
            let http = StubHTTPClient()
            http.stubStream(path: "/v1/chat/completions", chunks: [
                Data(payload[0..<cut]), Data(payload[cut...])
            ])

            let deltas = try await collect(
                OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
                    .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
            )

            #expect(deltas == ["Hello", " world"], "wrong deltas when split at byte \(cut)")
        }
    }

    @Test func chatIgnoresCommentHeartbeatsAndUsageOnlyChunks() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data("""
        : keep-alive

        data: {"choices":[{"delta":{"content":"x"}}]}

        data: {"choices":[],"usage":{"total_tokens":9}}

        data: [DONE]

        """.utf8)])

        let deltas = try await collect(
            OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
                .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
        )

        #expect(deltas == ["x"])
    }

    @Test func chatFinishesWhenTheStreamEndsWithoutADoneSentinel() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [
            Data(#"data: {"choices":[{"delta":{"content":"tail"}}]}"#.utf8)
        ])

        let deltas = try await collect(
            OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
                .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
        )

        #expect(deltas == ["tail"])
    }

    @Test func chatThrowsStreamMalformedForNonJSONEventData() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [Data("data: <html>oops</html>\n\n".utf8)])

        let stream = OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
            .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)

        await #expect(throws: MacomprendoError.providerStreamMalformed) {
            for try await _ in stream {}
        }
    }

    @Test func chatSurfacesHTTPErrorsFromTheTransport() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/v1/chat/completions", chunks: [], status: 429,
                        errorBody: #"{"error":"rate limit"}"#)

        let stream = OpenAICompatibleLLMProvider(endpoint: makeEndpoint(), apiKey: "sk", http: http)
            .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)

        await #expect(throws: MacomprendoError.providerHTTP(status: 429, body: #"{"error":"rate limit"}"#)) {
            for try await _ in stream {}
        }
    }
}
