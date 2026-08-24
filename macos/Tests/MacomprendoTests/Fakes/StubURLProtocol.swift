import Foundation

/// Intercepts every request made through `StubURLProtocol.makeSession()`.
/// Scripts are keyed by URL path.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stub: @unchecked Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var error: URLError?
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    static func set(
        path: String,
        status: Int = 200,
        headers: [String: String] = [:],
        chunks: [Data] = [],
        error: URLError? = nil
    ) {
        lock.withLock { stubs[path] = Stub(status: status, headers: headers, chunks: chunks, error: error) }
    }

    static func reset() {
        lock.withLock { stubs.removeAll() }
    }

    private static func stub(for path: String) -> Stub? {
        lock.withLock { stubs[path] }
    }

    /// A session whose every request is served by this protocol.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let stub = Self.stub(for: url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in stub.chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
