import Foundation
import Testing
@testable import Macomprendo

@Suite struct OllamaPullTests {

    private func makeEndpoint() -> Endpoint {
        Endpoint(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A11A")!,
            name: "Ollama (local)",
            kind: .ollama,
            baseURL: URL(string: "http://localhost:11434")!,
            apiKeyRef: nil
        )
    }

    private static let fixture = """
    {"status":"pulling manifest"}
    {"status":"pulling 8934d96d3f08","digest":"sha256:8934d9","total":986000000,"completed":0}
    {"status":"pulling 8934d96d3f08","digest":"sha256:8934d9","total":986000000,"completed":493000000}
    {"status":"verifying sha256 digest"}
    {"status":"success"}

    """

    private func collect(_ stream: AsyncThrowingStream<PullProgress, Error>) async throws -> [PullProgress] {
        var events: [PullProgress] = []
        for try await event in stream { events.append(event) }
        return events
    }

    @Test func pullPostsNameAndStreamTrue() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/pull", chunks: [Data((#"{"status":"success"}"# + "\n").utf8)])

        _ = try await collect(OllamaProvider(endpoint: makeEndpoint(), http: http).pull(model: "qwen2.5:1.5b"))

        let request = http.requests(forPath: "/api/pull")[0]
        #expect(request.method == "POST")
        #expect(request.url == URL(string: "http://localhost:11434/api/pull")!)
        #expect(request.headers["Content-Type"] == "application/json")

        let requestBody = try #require(request.body)
        let body = try #require(try JSONSerialization.jsonObject(with: requestBody) as? [String: Any])
        #expect(body["name"] as? String == "qwen2.5:1.5b")
        #expect(body["stream"] as? Bool == true)
    }

    @Test func pullYieldsEveryStatusLineWithOptionalByteCounts() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/pull", chunks: [Data(Self.fixture.utf8)])

        let events = try await collect(OllamaProvider(endpoint: makeEndpoint(), http: http).pull(model: "qwen2.5:1.5b"))

        #expect(events == [
            PullProgress(status: "pulling manifest", completed: nil, total: nil),
            PullProgress(status: "pulling 8934d96d3f08", completed: 0, total: 986_000_000),
            PullProgress(status: "pulling 8934d96d3f08", completed: 493_000_000, total: 986_000_000),
            PullProgress(status: "verifying sha256 digest", completed: nil, total: nil),
            PullProgress(status: "success", completed: nil, total: nil)
        ])
    }

    @Test func pullReassemblesProgressSplitAcrossChunkBoundaries() async throws {
        let payload = Array(Self.fixture.utf8)
        for cut in stride(from: 0, through: payload.count, by: 17) {
            let http = StubHTTPClient()
            http.stubStream(path: "/api/pull", chunks: [Data(payload[0..<cut]), Data(payload[cut...])])

            let events = try await collect(OllamaProvider(endpoint: makeEndpoint(), http: http).pull(model: "m"))

            #expect(events.count == 5, "wrong count when split at byte \(cut)")
            #expect(events.last?.status == "success", "lost the final line when split at byte \(cut)")
        }
    }

    @Test func pullThrowsStreamMalformedForANonJSONLine() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/pull", chunks: [Data("<html>502</html>\n".utf8)])

        let stream = OllamaProvider(endpoint: makeEndpoint(), http: http).pull(model: "m")

        await #expect(throws: MacomprendoError.providerStreamMalformed) {
            for try await _ in stream {}
        }
    }

    @Test func pullSurfacesHTTPErrorForAnUnknownModel() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/pull", chunks: [], status: 404,
                        errorBody: "pull model manifest: file does not exist")

        let stream = OllamaProvider(endpoint: makeEndpoint(), http: http).pull(model: "ghost")

        await #expect(throws: MacomprendoError.providerHTTP(
            status: 404, body: "pull model manifest: file does not exist"
        )) {
            for try await _ in stream {}
        }
    }
}
