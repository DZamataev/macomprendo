import Foundation
@testable import Macomprendo

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var _response = HTTPResponse(status: 200, headers: [:], body: Data())
    private var _error: Error?

    var requests: [HTTPRequest] { lock.withLock { _requests } }

    var response: HTTPResponse {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        if let error { throw error }
        return response
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<Data, Error> {
        lock.withLock { _requests.append(request) }
        let error = self.error
        let body = response.body
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.yield(body)
                continuation.finish()
            }
        }
    }
}
