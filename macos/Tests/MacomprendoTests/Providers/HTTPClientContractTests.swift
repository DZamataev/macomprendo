import Foundation
import Testing
@testable import Macomprendo

@Suite struct HTTPClientContractTests {

    @Test func requestDefaultsAreGetWithTenSecondTimeout() {
        let request = HTTPRequest(url: URL(string: "http://localhost:11434/api/tags")!)
        #expect(request.method == "GET")
        #expect(request.headers.isEmpty)
        #expect(request.body == nil)
        #expect(request.timeout == 10)
    }

    @Test func stubReturnsScriptedBodyAndRecordsTheRequest() async throws {
        let http = StubHTTPClient()
        http.stub(path: "/api/tags", body: Data(#"{"models":[]}"#.utf8))

        let response = try await http.send(
            HTTPRequest(url: URL(string: "http://localhost:11434/api/tags")!,
                        headers: ["X-Test": "1"])
        )

        #expect(response.status == 200)
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"models":[]}"#)
        #expect(http.requests.count == 1)
        #expect(http.requests[0].method == "GET")
        #expect(http.requests[0].url.path == "/api/tags")
        #expect(http.requests[0].headers["X-Test"] == "1")
    }

    @Test func stubDistinguishesMethodsOnTheSamePath() async throws {
        let http = StubHTTPClient()
        http.stub("HEAD", path: "/file.bin", headers: ["Content-Length": "42"])
        http.stub("GET", path: "/file.bin", body: Data("payload".utf8))

        let head = try await http.send(HTTPRequest(method: "HEAD", url: URL(string: "https://example.com/file.bin")!))
        let get = try await http.send(HTTPRequest(url: URL(string: "https://example.com/file.bin")!))

        #expect(head.headers["Content-Length"] == "42")
        #expect(String(decoding: get.body, as: UTF8.self) == "payload")
    }

    @Test func stubThrowsProviderHTTPForNonSuccessStatus() async {
        let http = StubHTTPClient()
        http.stub(path: "/v1/models", status: 401, body: Data(#"{"error":"bad key"}"#.utf8))

        await #expect(throws: MacomprendoError.providerHTTP(status: 401, body: #"{"error":"bad key"}"#)) {
            _ = try await http.send(HTTPRequest(url: URL(string: "https://api.example.com/v1/models")!))
        }
    }

    @Test func stubThrowsWhenNoScriptMatches() async {
        let http = StubHTTPClient()
        await #expect(throws: MacomprendoError.self) {
            _ = try await http.send(HTTPRequest(url: URL(string: "https://api.example.com/nope")!))
        }
    }

    @Test func stubStreamsScriptedChunksInOrder() async throws {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [Data("a".utf8), Data("bc".utf8), Data("d".utf8)])

        var received: [String] = []
        for try await chunk in http.stream(HTTPRequest(method: "POST", url: URL(string: "http://localhost:11434/api/chat")!)) {
            received.append(String(decoding: chunk, as: UTF8.self))
        }

        #expect(received == ["a", "bc", "d"])
        #expect(http.requests.count == 1)
        #expect(http.requests[0].method == "POST")
    }

    @Test func stubStreamThrowsBeforeAnyChunkOnNonSuccessStatus() async {
        let http = StubHTTPClient()
        http.stubStream(path: "/api/chat", chunks: [Data("never".utf8)], status: 500,
                        errorBody: "internal error")

        var received: [Data] = []
        await #expect(throws: MacomprendoError.providerHTTP(status: 500, body: "internal error")) {
            for try await chunk in http.stream(HTTPRequest(method: "POST", url: URL(string: "http://x/api/chat")!)) {
                received.append(chunk)
            }
        }
        #expect(received.isEmpty)
    }

    @Test func stubReplaysScriptedTransportFailure() async {
        let http = StubHTTPClient()
        http.stubError(path: "/api/tags", error: .providerUnreachable(endpointName: "localhost"))

        await #expect(throws: MacomprendoError.providerUnreachable(endpointName: "localhost")) {
            _ = try await http.send(HTTPRequest(url: URL(string: "http://localhost:11434/api/tags")!))
        }
    }
}
