import Foundation
@testable import Macomprendo

/// Scripted `HTTPClient` for tests. Scripts are keyed by `"<METHOD> <path>"`
/// so a `HEAD` and a `GET` on the same path can behave differently.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {

    struct Script: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()
        var chunks: [Data] = []
        var errorBody: String = ""
        var failure: MacomprendoError?
    }

    private let lock = NSLock()
    private var scripts: [String: Script] = [:]
    private var recorded: [HTTPRequest] = []

    /// Every request the client has been asked to perform, in order.
    var requests: [HTTPRequest] {
        lock.withLock { recorded }
    }

    /// Requests recorded for one URL path, in order.
    func requests(forPath path: String) -> [HTTPRequest] {
        lock.withLock { recorded.filter { $0.url.path == path } }
    }

    // MARK: - Scripting

    func stub(
        _ method: String = "GET",
        path: String,
        status: Int = 200,
        headers: [String: String] = [:],
        body: Data = Data()
    ) {
        setScript(method, path, Script(status: status, headers: headers, body: body))
    }

    func stubStream(
        _ method: String = "POST",
        path: String,
        chunks: [Data],
        status: Int = 200,
        headers: [String: String] = [:],
        errorBody: String = ""
    ) {
        setScript(method, path, Script(status: status, headers: headers, chunks: chunks, errorBody: errorBody))
    }

    func stubError(_ method: String = "GET", path: String, error: MacomprendoError) {
        setScript(method, path, Script(failure: error))
    }

    private func setScript(_ method: String, _ path: String, _ script: Script) {
        lock.withLock { scripts["\(method.uppercased()) \(path)"] = script }
    }

    private func script(for request: HTTPRequest) -> Script? {
        lock.withLock { scripts["\(request.method.uppercased()) \(request.url.path)"] }
    }

    private func record(_ request: HTTPRequest) {
        lock.withLock { recorded.append(request) }
    }

    // MARK: - HTTPClient

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        record(request)
        guard let script = script(for: request) else {
            throw MacomprendoError.providerHTTP(
                status: 599,
                body: "StubHTTPClient: no script for \(request.method.uppercased()) \(request.url.path)"
            )
        }
        if let failure = script.failure { throw failure }
        guard (200..<300).contains(script.status) else {
            throw MacomprendoError.providerHTTP(
                status: script.status,
                body: String(decoding: script.body, as: UTF8.self)
            )
        }
        return HTTPResponse(status: script.status, headers: script.headers, body: script.body)
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        record(request)
        let script = script(for: request)
        return AsyncThrowingStream { continuation in
            guard let script else {
                continuation.finish(throwing: MacomprendoError.providerHTTP(
                    status: 599,
                    body: "StubHTTPClient: no script for \(request.method.uppercased()) \(request.url.path)"
                ))
                return
            }
            if let failure = script.failure {
                continuation.finish(throwing: failure)
                return
            }
            guard (200..<300).contains(script.status) else {
                continuation.finish(throwing: MacomprendoError.providerHTTP(
                    status: script.status,
                    body: script.errorBody
                ))
                return
            }
            for chunk in script.chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
