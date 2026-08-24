import Foundation
import Testing
@testable import Macomprendo

@Suite struct ProviderFactoryTests {

    private let ollamaID = UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!
    private let openAIID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func ollamaEndpoint() -> Endpoint {
        Endpoint(id: ollamaID, name: "Ollama (local)", kind: .ollama,
                 baseURL: URL(string: "http://localhost:11434")!, apiKeyRef: nil)
    }

    private func openAIEndpoint(apiKeyRef: String? = "example-key") -> Endpoint {
        Endpoint(id: openAIID, name: "Example AI", kind: .openAICompatible,
                 baseURL: URL(string: "https://api.example.com")!, apiKeyRef: apiKeyRef)
    }

    // MARK: - llm(for:)

    @Test func buildsANativeOllamaProviderForOllamaEndpoints() async throws {
        // Behavioural check: only the native provider calls /api/tags.
        let http = StubHTTPClient()
        http.stub(path: "/api/tags", body: Data(#"{"models":[{"name":"qwen2.5:1.5b"}]}"#.utf8))
        let factory = ProviderFactory(http: http, keychain: InMemoryKeychainStore())

        let provider = try factory.llm(for: ollamaEndpoint())
        let models = try await provider.listModels()

        #expect(provider is OllamaProvider)
        #expect(models == ["qwen2.5:1.5b"])
        #expect(http.requests[0].url == URL(string: "http://localhost:11434/api/tags")!)
        #expect(provider.endpoint.id == ollamaID)
    }

    @Test func buildsAnOpenAIProviderForOpenAICompatibleEndpoints() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"data":[{"id":"gpt-4o-mini"}]}"#.utf8))
        let keychain = InMemoryKeychainStore()
        try keychain.set("sk-secret", account: "example-key")
        let factory = ProviderFactory(http: http, keychain: keychain)

        let provider = try factory.llm(for: openAIEndpoint())
        let models = try await provider.listModels()

        #expect(provider is OpenAICompatibleLLMProvider)
        #expect(models == ["gpt-4o-mini"])
        #expect(http.requests[0].url == URL(string: "https://api.example.com/v1/models")!)
    }

    @Test func loadsTheAPIKeyFromTheKeychainAndSendsItAsABearerToken() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"data":[]}"#.utf8))
        let keychain = InMemoryKeychainStore()
        try keychain.set("sk-secret", account: "example-key")
        let factory = ProviderFactory(http: http, keychain: keychain)

        _ = try await factory.llm(for: openAIEndpoint()).listModels()

        #expect(http.requests[0].headers["Authorization"] == "Bearer sk-secret")
    }

    @Test func sendsNoAuthorizationWhenTheEndpointHasNoKeyReference() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"data":[]}"#.utf8))
        let factory = ProviderFactory(http: http, keychain: InMemoryKeychainStore())

        _ = try await factory.llm(for: openAIEndpoint(apiKeyRef: nil)).listModels()

        #expect(http.requests[0].headers["Authorization"] == nil)
    }

    @Test func sendsNoAuthorizationWhenTheReferencedKeyIsAbsentFromTheKeychain() async throws {
        // Better to let the server answer 401 (an actionable providerHTTP error)
        // than to fail opaquely before the request goes out.
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", body: Data(#"{"data":[]}"#.utf8))
        let factory = ProviderFactory(http: http, keychain: InMemoryKeychainStore())

        _ = try await factory.llm(for: openAIEndpoint()).listModels()

        #expect(http.requests[0].headers["Authorization"] == nil)
    }

    // MARK: - transcriber(for:endpoints:models:)

    @Test func buildsAWhisperTranscriberForADownloadedLocalModel() async throws {
        let modelURL = URL(fileURLWithPath: "/models/ggml-base.bin")
        let models = FakeModelManager(localURLs: ["base": modelURL])
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())

        let transcriber = try await factory.transcriber(
            for: .local(modelID: "base"), endpoints: [], models: models
        )

        #expect(transcriber is WhisperCppTranscriber)
    }

    @Test func throwsModelMissingWhenTheLocalModelIsNotDownloaded() async {
        let models = FakeModelManager()
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())

        await #expect(throws: MacomprendoError.modelMissing("large-v3-turbo")) {
            _ = try await factory.transcriber(
                for: .local(modelID: "large-v3-turbo"), endpoints: [], models: models
            )
        }
    }

    @Test func buildsARemoteTranscriberForAnEndpointSource() async throws {
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions", body: Data(#"{"text":"hi"}"#.utf8))
        let keychain = InMemoryKeychainStore()
        try keychain.set("sk-secret", account: "example-key")
        let factory = ProviderFactory(http: http, keychain: keychain)

        let transcriber = try await factory.transcriber(
            for: .endpoint(id: openAIID, model: "whisper-1"),
            endpoints: [ollamaEndpoint(), openAIEndpoint()],
            models: FakeModelManager()
        )
        let text = try await transcriber.transcribe([0.0], sampleRate: 16_000, language: nil)

        #expect(transcriber is OpenAICompatibleTranscriber)
        #expect(text == "hi")
        #expect(http.requests[0].url == URL(string: "https://api.example.com/v1/audio/transcriptions")!)
        #expect(http.requests[0].headers["Authorization"] == "Bearer sk-secret")
    }

    @Test func passesTheSelectedTranscriptionModelThrough() async throws {
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions", body: Data(#"{"text":"hi"}"#.utf8))
        let factory = ProviderFactory(http: http, keychain: InMemoryKeychainStore())

        let transcriber = try await factory.transcriber(
            for: .endpoint(id: openAIID, model: "whisper-large-v3"),
            endpoints: [openAIEndpoint(apiKeyRef: nil)],
            models: FakeModelManager()
        )
        _ = try await transcriber.transcribe([0.0], sampleRate: 16_000, language: nil)

        let body = String(decoding: try #require(http.requests[0].body), as: UTF8.self)
        #expect(body.contains("whisper-large-v3"))
    }

    @Test func throwsUnreachableWhenTheSelectedEndpointIsNoLongerInSettings() async {
        let factory = ProviderFactory(http: StubHTTPClient(), keychain: InMemoryKeychainStore())
        let missingID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!

        await #expect(throws: MacomprendoError.providerUnreachable(
            endpointName: missingID.uuidString
        )) {
            _ = try await factory.transcriber(
                for: .endpoint(id: missingID, model: "whisper-1"),
                endpoints: [ollamaEndpoint()],
                models: FakeModelManager()
            )
        }
    }
}
