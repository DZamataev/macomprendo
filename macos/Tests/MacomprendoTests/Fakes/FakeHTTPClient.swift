import Foundation
@testable import Macomprendo

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var _response = HTTPResponse(status: 200, headers: [:], body: Data())
    private var _error: Error?
    private var _isGated = false
    private var _gateContinuation: CheckedContinuation<Void, Error>?
    private var _gateWasCancelled = false

    var requests: [HTTPRequest] { lock.withLock { _requests } }

    var response: HTTPResponse {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }

    var error: Error? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    /// When `true`, `send` suspends indefinitely instead of resolving, until the awaiting
    /// task is cancelled — lets a test hold a request "in flight" and observe that
    /// cancellation actually reaches it, the way `URLSessionHTTPClient` (backed by
    /// `URLSession.data(for:)`) genuinely aborts a live connection.
    var isGated: Bool {
        get { lock.withLock { _isGated } }
        set { lock.withLock { _isGated = newValue } }
    }

    /// `true` once a gated `send` was cancelled rather than left hanging or resolved normally.
    var gateWasCancelled: Bool { lock.withLock { _gateWasCancelled } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { _requests.append(request) }
        if isGated {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock {
                        if _gateWasCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            _gateContinuation = continuation
                        }
                    }
                }
            } onCancel: {
                let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                    _gateWasCancelled = true
                    let pending = _gateContinuation
                    _gateContinuation = nil
                    return pending
                }
                continuation?.resume(throwing: CancellationError())
            }
        }
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
