import Foundation
import Testing
@testable import Macomprendo

@Suite struct OpenAICompatibleTranscriberTests {

    private let boundary = "TESTBOUNDARY"

    private func makeEndpoint(_ baseURL: String = "https://api.example.com") -> Endpoint {
        Endpoint(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Example AI",
            kind: .openAICompatible,
            baseURL: URL(string: baseURL)!,
            apiKeyRef: "example-key"
        )
    }

    private func makeTranscriber(
        _ http: StubHTTPClient,
        baseURL: String = "https://api.example.com",
        apiKey: String? = "sk-test",
        model: String = "whisper-1"
    ) -> OpenAICompatibleTranscriber {
        OpenAICompatibleTranscriber(
            endpoint: makeEndpoint(baseURL), apiKey: apiKey, model: model,
            http: http, boundary: boundary
        )
    }

    private func stubOK(_ http: StubHTTPClient, text: String = "Hello world.") {
        http.stub("POST", path: "/v1/audio/transcriptions",
                  body: Data("{\"text\":\"\(text)\"}".utf8))
    }

    @Test func postsToTheNormalisedTranscriptionsURLWithBearerAndMultipartHeaders() async throws {
        let http = StubHTTPClient()
        stubOK(http)

        _ = try await makeTranscriber(http).transcribe([0.0, 0.5], sampleRate: 16_000, language: nil)

        let request = http.requests[0]
        #expect(request.method == "POST")
        #expect(request.url == URL(string: "https://api.example.com/v1/audio/transcriptions")!)
        #expect(request.headers["Authorization"] == "Bearer sk-test")
        #expect(request.headers["Content-Type"] == "multipart/form-data; boundary=TESTBOUNDARY")
        #expect(request.timeout == 120)
    }

    @Test func doesNotDoubleTheV1SegmentForABaseURLThatHasIt() async throws {
        let http = StubHTTPClient()
        stubOK(http)

        _ = try await makeTranscriber(http, baseURL: "http://localhost:1234/v1", apiKey: nil)
            .transcribe([0.0], sampleRate: 16_000, language: nil)

        #expect(http.requests[0].url == URL(string: "http://localhost:1234/v1/audio/transcriptions")!)
        #expect(http.requests[0].headers["Authorization"] == nil)
    }

    @Test func bodyStartsWithTheFilePartAndCarriesTheWAVBytes() async throws {
        let http = StubHTTPClient()
        stubOK(http)
        let pcm: [Float] = [0.0, 1.0, -1.0, 0.5]

        _ = try await makeTranscriber(http).transcribe(pcm, sampleRate: 16_000, language: nil)

        let body = try #require(http.requests[0].body)
        let prefix = """
        --TESTBOUNDARY\r
        Content-Disposition: form-data; name="file"; filename="audio.wav"\r
        Content-Type: audio/wav\r
        \r

        """
        #expect(body.starts(with: Array(prefix.utf8)))

        let wav = WAVEncoder.encode(pcm: pcm, sampleRate: 16_000)
        #expect(body.range(of: wav) != nil)
        #expect(body.count == Array(prefix.utf8).count + wav.count
                + Array("\r\n".utf8).count + fieldsLength(language: nil)
                + Array("--TESTBOUNDARY--\r\n".utf8).count)
    }

    /// Byte length of the `model` and `response_format` parts (plus `language` when given).
    private func fieldsLength(language: String?) -> Int {
        var fields = [("model", "whisper-1"), ("response_format", "json")]
        if let language { fields.append(("language", language)) }
        return fields.reduce(0) { total, field in
            total + Array("""
            --TESTBOUNDARY\r
            Content-Disposition: form-data; name="\(field.0)"\r
            \r
            \(field.1)\r

            """.utf8).count
        }
    }

    @Test func bodyContainsModelAndJSONResponseFormatFields() async throws {
        let http = StubHTTPClient()
        stubOK(http)

        _ = try await makeTranscriber(http, model: "whisper-large-v3")
            .transcribe([0.0], sampleRate: 16_000, language: nil)

        let body = String(decoding: try #require(http.requests[0].body), as: UTF8.self)
        #expect(body.contains("""
        --TESTBOUNDARY\r
        Content-Disposition: form-data; name="model"\r
        \r
        whisper-large-v3\r

        """))
        #expect(body.contains("""
        --TESTBOUNDARY\r
        Content-Disposition: form-data; name="response_format"\r
        \r
        json\r

        """))
        #expect(body.hasSuffix("--TESTBOUNDARY--\r\n"))
    }

    @Test func includesTheLanguageFieldOnlyWhenOneIsGiven() async throws {
        let withLanguage = StubHTTPClient()
        stubOK(withLanguage)
        _ = try await makeTranscriber(withLanguage).transcribe([0.0], sampleRate: 16_000, language: "ru")
        let withBody = String(decoding: try #require(withLanguage.requests[0].body), as: UTF8.self)
        #expect(withBody.contains("""
        Content-Disposition: form-data; name="language"\r
        \r
        ru\r

        """))

        let auto = StubHTTPClient()
        stubOK(auto)
        _ = try await makeTranscriber(auto).transcribe([0.0], sampleRate: 16_000, language: nil)
        let autoBody = String(decoding: try #require(auto.requests[0].body), as: UTF8.self)
        #expect(!autoBody.contains(#"name="language""#))

        let empty = StubHTTPClient()
        stubOK(empty)
        _ = try await makeTranscriber(empty).transcribe([0.0], sampleRate: 16_000, language: "")
        let emptyBody = String(decoding: try #require(empty.requests[0].body), as: UTF8.self)
        #expect(!emptyBody.contains(#"name="language""#))
    }

    @Test func returnsTheTextFieldTrimmed() async throws {
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions",
                  body: Data(#"{"text":"  Hello world.  "}"#.utf8))

        let text = try await makeTranscriber(http).transcribe([0.0], sampleRate: 16_000, language: nil)

        #expect(text == "Hello world.")
    }

    @Test func throwsStreamMalformedWhenTheResponseHasNoTextField() async {
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions",
                  body: Data(#"{"segments":[]}"#.utf8))

        await #expect(throws: MacomprendoError.providerStreamMalformed) {
            _ = try await makeTranscriber(http).transcribe([0.0], sampleRate: 16_000, language: nil)
        }
    }

    @Test func propagatesHTTPErrors() async {
        let http = StubHTTPClient()
        http.stub("POST", path: "/v1/audio/transcriptions", status: 413,
                  body: Data("file too large".utf8))

        await #expect(throws: MacomprendoError.providerHTTP(status: 413, body: "file too large")) {
            _ = try await makeTranscriber(http).transcribe([0.0], sampleRate: 16_000, language: nil)
        }
    }

    @Test func generatesAUniqueBoundaryWhenNoneIsSupplied() async throws {
        let http = StubHTTPClient()
        stubOK(http)

        _ = try await OpenAICompatibleTranscriber(
            endpoint: makeEndpoint(), apiKey: nil, model: "whisper-1", http: http
        ).transcribe([0.0], sampleRate: 16_000, language: nil)

        let contentType = try #require(http.requests[0].headers["Content-Type"])
        #expect(contentType.hasPrefix("multipart/form-data; boundary=macomprendo-"))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let body = String(decoding: try #require(http.requests[0].body), as: UTF8.self)
        #expect(body.hasPrefix("--\(boundary)\r\n"))
        #expect(body.hasSuffix("--\(boundary)--\r\n"))
    }
}
