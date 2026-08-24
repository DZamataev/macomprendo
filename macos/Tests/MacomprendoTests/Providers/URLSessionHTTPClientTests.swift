import Foundation
import Testing
@testable import Macomprendo

@Suite(.serialized) struct URLSessionHTTPClientTests {

    private func makeClient() -> URLSessionHTTPClient {
        StubURLProtocol.reset()
        return URLSessionHTTPClient(session: StubURLProtocol.makeSession())
    }

    @Test func sendReturnsStatusHeadersAndBody() async throws {
        let client = makeClient()
        StubURLProtocol.set(
            path: "/api/tags",
            headers: ["Content-Type": "application/json"],
            chunks: [Data(#"{"models":[]}"#.utf8)]
        )

        let response = try await client.send(
            HTTPRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        )

        #expect(response.status == 200)
        #expect(response.header("content-type") == "application/json")
        #expect(String(decoding: response.body, as: UTF8.self) == #"{"models":[]}"#)
    }

    @Test func sendThrowsProviderHTTPWithBodyForNonSuccessStatus() async {
        let client = makeClient()
        StubURLProtocol.set(path: "/v1/models", status: 401, chunks: [Data("unauthorized".utf8)])

        await #expect(throws: MacomprendoError.providerHTTP(status: 401, body: "unauthorized")) {
            _ = try await client.send(HTTPRequest(url: URL(string: "https://api.example.com/v1/models")!))
        }
    }

    @Test func sendMapsConnectionFailureToProviderUnreachableWithHost() async {
        let client = makeClient()
        StubURLProtocol.set(path: "/api/tags", error: URLError(.cannotConnectToHost))

        await #expect(throws: MacomprendoError.providerUnreachable(endpointName: "127.0.0.1")) {
            _ = try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!))
        }
    }

    @Test func streamYieldsAllBytesAndSplitsOnNewlines() async throws {
        let client = makeClient()
        StubURLProtocol.set(path: "/api/chat", chunks: [Data("one\ntw".utf8), Data("o\n".utf8)])

        var chunks: [String] = []
        for try await chunk in client.stream(HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:11434/api/chat")!)) {
            chunks.append(String(decoding: chunk, as: UTF8.self))
        }

        #expect(chunks.joined() == "one\ntwo\n")
        #expect(chunks.count == 2)
        #expect(chunks[0] == "one\n")
        #expect(chunks[1] == "two\n")
    }

    @Test func streamThrowsProviderHTTPBeforeYieldingAnythingOnNonSuccessStatus() async {
        let client = makeClient()
        StubURLProtocol.set(path: "/api/chat", status: 500, chunks: [Data("boom".utf8)])

        var chunks: [Data] = []
        await #expect(throws: MacomprendoError.providerHTTP(status: 500, body: "boom")) {
            for try await chunk in client.stream(HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:11434/api/chat")!)) {
                chunks.append(chunk)
            }
        }
        #expect(chunks.isEmpty)
    }

    @Test func streamMapsConnectionFailureToProviderUnreachable() async {
        let client = makeClient()
        StubURLProtocol.set(path: "/api/chat", error: URLError(.networkConnectionLost))

        await #expect(throws: MacomprendoError.providerUnreachable(endpointName: "127.0.0.1")) {
            for try await _ in client.stream(HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:11434/api/chat")!)) {}
        }
    }

    @Test func sendMapsCancellationToCancelledError() async {
        let client = makeClient()
        StubURLProtocol.set(path: "/api/tags", error: URLError(.cancelled))

        await #expect(throws: MacomprendoError.cancelled) {
            _ = try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!))
        }
    }

    @Test func sendCancelledMidRequestThrowsCancelled() async throws {
        let client = makeClient()
        // The request is still in flight (URLProtocol is mid-`Thread.sleep` before its
        // second chunk) when the surrounding Task is cancelled for real, so this
        // exercises live `Task` cancellation rather than a scripted transport error.
        StubURLProtocol.set(path: "/api/tags", chunks: [Data("first".utf8), Data("second".utf8)], chunkDelay: 0.3)

        let task = Task<HTTPResponse, Error> {
            try await client.send(HTTPRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!))
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        await #expect(throws: MacomprendoError.cancelled) {
            _ = try await task.value
        }
    }

    @Test func streamMapsScriptedCancellationToCancelledError() async {
        let client = makeClient()
        StubURLProtocol.set(path: "/api/chat", error: URLError(.cancelled))

        await #expect(throws: MacomprendoError.cancelled) {
            for try await _ in client.stream(HTTPRequest(method: "POST", url: URL(string: "http://127.0.0.1:11434/api/chat")!)) {}
        }
    }

    @Test func requestCarriesMethodHeadersBodyAndTimeout() {
        let request = HTTPRequest(
            method: "POST",
            url: URL(string: "https://api.example.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer k", "Content-Type": "application/json"],
            body: Data("{}".utf8),
            timeout: 60
        )

        let urlRequest = URLSessionHTTPClient.makeURLRequest(request)

        #expect(urlRequest.httpMethod == "POST")
        #expect(urlRequest.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        #expect(urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(urlRequest.httpBody == Data("{}".utf8))
        #expect(urlRequest.timeoutInterval == 60)
    }
}
