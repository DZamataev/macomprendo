import Foundation

/// Intercepts every request made through `StubURLProtocol.makeSession()`.
/// Scripts are keyed by URL path.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stub: @unchecked Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var chunks: [Data] = []
        var error: URLError?
        /// Delay inserted before each chunk after the first, so tests can cancel
        /// mid-stream deterministically instead of racing chunk delivery.
        var chunkDelay: TimeInterval = 0
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var stubs: [String: Stub] = [:]

    static func set(
        path: String,
        status: Int = 200,
        headers: [String: String] = [:],
        chunks: [Data] = [],
        error: URLError? = nil,
        chunkDelay: TimeInterval = 0
    ) {
        lock.withLock {
            stubs[path] = Stub(status: status, headers: headers, chunks: chunks, error: error, chunkDelay: chunkDelay)
        }
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
        for (index, chunk) in stub.chunks.enumerated() {
            if index > 0, stub.chunkDelay > 0 {
                Thread.sleep(forTimeInterval: stub.chunkDelay)
            }
            if stopped.withLock({ $0 }) { return }
            client?.urlProtocol(self, didLoad: chunk)
        }
        if stopped.withLock({ $0 }) { return }
        client?.urlProtocolDidFinishLoading(self)
    }

    /// Set by `stopLoading()` when the owning `URLSessionTask` is cancelled, so an
    /// in-flight `startLoading()` (possibly mid-`Thread.sleep`, simulating a slow
    /// chunk) stops delivering further chunks instead of racing the cancellation.
    private let stopped = Locked(false)

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

/// Minimal lock-protected box; `StubURLProtocol` instances are touched from both the
/// URL loading system's background queue and, via `stopLoading()`, the calling task's
/// cancellation path.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
