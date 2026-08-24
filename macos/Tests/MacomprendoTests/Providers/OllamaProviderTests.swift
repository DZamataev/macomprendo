import Foundation
import Testing
@testable import Macomprendo

@Suite struct OllamaProviderTests {

    private func makeEndpoint() -> Endpoint {
        Endpoint(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!,
            name: "Ollama (local)",
            kind: .ollama,
            baseURL: URL(string: "http://localhost:11434")!,
            apiKeyRef: nil
        )
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var deltas: [String] = []
        for try await delta in stream { deltas.append(delta) }
        return deltas
    }

    private func jsonBody(_ request: HTTPRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - listModels

    @Test func listModelsReturnsTheNameOfEveryInstalledModel() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/api/tags", body: Data(#"""
        {"models":[
          {"name":"qwen2.5:1.5b","size":986000000,"digest":"abc"},
          {"name":"llama3.2:3b","size":2000000000,"digest":"def"}
        ]}
        """#.utf8))

        let models = try await OllamaProvider(endpoint: makeEndpoint(), http: http).listModels()

        #expect(models == ["qwen2.5:1.5b", "llama3.2:3b"])
        #expect(http.requests[0].method == "GET")
        #expect(http.requests[0].url == URL(string: "http://localhost:11434/api/tags")!)
    }

    @Test func listModelsReturnsEmptyArrayWhenNoModelsAreInstalled() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/api/tags", body: Data(#"{"models":[]}"#.utf8))

        let models = try await OllamaProvider(endpoint: makeEndpoint(), http: http).listModels()

        #expect(models.isEmpty)
    }

    @Test func listModelsThrowsStreamMalformedForUnexpectedJSON() async {
        let http = StubHTTPClient()
        http.stub(path: "/api/tags", body: Data(#"{"unexpected":true}"#.utf8))

        await #expect(throws: MacomprendoError.providerStreamMalformed) {
            _ = try await OllamaProvider(endpoint: makeEndpoint(), http: http).listModels()
        }
    }

    @Test func listModelsPropagatesUnreachableEndpoint() async {
        let http = StubHTTPClient()
        http.stubError(path: "/api/tags", error: .providerUnreachable(endpointName: "localhost"))

        await #expect(throws: MacomprendoError.providerUnreachable(endpointName: "localhost")) {
            _ = try await OllamaProvider(endpoint: makeEndpoint(), http: http).listModels()
        }
    }

    // MARK: - chat request shape

    @Test func chatPostsModelMessagesStreamAndTemperature() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [
            Data((#"{"message":{"role":"assistant","content":"ok"},"done":false}"# + "\n").utf8),
            Data((#"{"message":{"role":"assistant","content":""},"done":true}"# + "\n").utf8)
        ])

        _ = try await collect(
            OllamaProvider(endpoint: makeEndpoint(), http: http).chat(
                [ChatMessage(role: .system, content: "Return only the result."),
                 ChatMessage(role: .user, content: "clean up: helo")],
                model: "qwen2.5:1.5b",
                options: ChatOptions(temperature: 0.7)
            )
        )

        let request = http.requests(forPath: "/api/chat")[0]
        #expect(request.method == "POST")
        #expect(request.url == URL(string: "http://localhost:11434/api/chat")!)
        #expect(request.headers["Content-Type"] == "application/json")

        let body = try jsonBody(request)
        #expect(body["model"] as? String == "qwen2.5:1.5b")
        #expect(body["stream"] as? Bool == true)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["temperature"] as? Double == 0.7)
        #expect(options["num_predict"] == nil)
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages == [
            ["role": "system", "content": "Return only the result."],
            ["role": "user", "content": "clean up: helo"]
        ])
    }

    @Test func chatMapsMaxTokensToNumPredictWhenSet() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [
            Data((#"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n").utf8)
        ])

        _ = try await collect(
            OllamaProvider(endpoint: makeEndpoint(), http: http).chat(
                [ChatMessage(role: .user, content: "hi")],
                model: "qwen2.5:1.5b",
                options: ChatOptions(temperature: 0.7, maxTokens: 256)
            )
        )

        let request = http.requests(forPath: "/api/chat")[0]
        let body = try jsonBody(request)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] as? Int == 256)
    }

    @Test func chatOmitsNumPredictWhenMaxTokensIsNil() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [
            Data((#"{"message":{"role":"assistant","content":"ok"},"done":true}"# + "\n").utf8)
        ])

        _ = try await collect(
            OllamaProvider(endpoint: makeEndpoint(), http: http).chat(
                [ChatMessage(role: .user, content: "hi")],
                model: "qwen2.5:1.5b",
                options: ChatOptions(temperature: 0.7, maxTokens: nil)
            )
        )

        let request = http.requests(forPath: "/api/chat")[0]
        let body = try jsonBody(request)
        let options = try #require(body["options"] as? [String: Any])
        #expect(options["num_predict"] == nil)
    }

    // MARK: - chat streaming

    @Test func chatYieldsOneDeltaPerNonEmptyContentAndStopsOnDone() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [Data("""
        {"message":{"role":"assistant","content":"Hello"},"done":false}
        {"message":{"role":"assistant","content":" world"},"done":false}
        {"message":{"role":"assistant","content":""},"done":true,"total_duration":1234}

        """.utf8)])

        let deltas = try await collect(
            OllamaProvider(endpoint: makeEndpoint(), http: http)
                .chat([ChatMessage(role: .user, content: "hi")], model: "qwen2.5:1.5b", options: .default)
        )

        #expect(deltas == ["Hello", " world"])
    }

    @Test func chatReassemblesDeltasSplitAcrossArbitraryChunkBoundaries() async throws {
        let payload = Array("""
        {"message":{"role":"assistant","content":"Hel"},"done":false}
        {"message":{"role":"assistant","content":"lo"},"done":false}
        {"message":{"role":"assistant","content":""},"done":true}

        """.utf8)

        for cut in stride(from: 0, through: payload.count, by: 13) {
            let http = StubHTTPClient()
            http.stubStream(path: "/api/chat", chunks: [
                Data(payload[0..<cut]), Data(payload[cut...])
            ])

            let deltas = try await collect(
                OllamaProvider(endpoint: makeEndpoint(), http: http)
                    .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
            )

            #expect(deltas == ["Hel", "lo"], "wrong deltas when split at byte \(cut)")
        }
    }

    @Test func chatFinishesWhenTheStreamEndsWithoutATrailingNewline() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [
            Data(#"{"message":{"role":"assistant","content":"tail"},"done":false}"#.utf8)
        ])

        let deltas = try await collect(
            OllamaProvider(endpoint: makeEndpoint(), http: http)
                .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)
        )

        #expect(deltas == ["tail"])
    }

    @Test func chatThrowsStreamMalformedForANonJSONLine() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [Data("not json at all\n".utf8)])

        let stream = OllamaProvider(endpoint: makeEndpoint(), http: http)
            .chat([ChatMessage(role: .user, content: "hi")], model: "m", options: .default)

        await #expect(throws: MacomprendoError.providerStreamMalformed) {
            for try await _ in stream {}
        }
    }

    @Test func chatSurfacesHTTPErrorsFromTheTransport() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [], status: 404, errorBody: "model not found")

        let stream = OllamaProvider(endpoint: makeEndpoint(), http: http)
            .chat([ChatMessage(role: .user, content: "hi")], model: "ghost", options: .default)

        await #expect(throws: MacomprendoError.providerHTTP(status: 404, body: "model not found")) {
            for try await _ in stream {}
        }
    }
}
