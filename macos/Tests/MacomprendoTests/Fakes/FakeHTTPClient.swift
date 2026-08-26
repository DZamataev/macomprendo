import Foundation
@testable import Macomprendo

final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var _response = HTTPResponse(status: 200, headers: [:], body: Data())
    private var _error: Error?
    private var _isGated = false
    /// When `true`, a cancelled gate stays suspended (instead of resuming itself immediately)
    /// until the test calls `releaseGate(at:)` — lets a test control exactly when a cancelled
    /// request's unwind code runs relative to other work, mirroring the real delay between
    /// calling `Task.cancel()` and `URLSession`'s cancellation actually propagating.
    private var _holdCancellations = false
    /// Keyed by the request's index in `requests`, so concurrently in-flight gated requests
    /// (one per generation) each get their own continuation instead of clobbering a shared one.
    private var _gateContinuations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var _gateCancelled: Set<Int> = []

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

    var holdCancellations: Bool {
        get { lock.withLock { _holdCancellations } }
        set { lock.withLock { _holdCancellations = newValue } }
    }

    /// `true` once *any* gated `send` was cancelled rather than left hanging or resolved
    /// normally. Kept for tests that only ever have one request gated at a time.
    var gateWasCancelled: Bool { lock.withLock { !_gateCancelled.isEmpty } }

    /// `true` once the gated `send` at `index` (0-based, matching `requests`) was cancelled.
    func gateWasCancelled(at index: Int) -> Bool { lock.withLock { _gateCancelled.contains(index) } }

    /// Lets a `holdCancellations`-suspended gate at `index` actually resume: throws
    /// `CancellationError` if that request was cancelled, otherwise completes normally.
    /// No-op if the gate at `index` isn't currently suspended (already released, or never
    /// gated).
    func releaseGate(at index: Int) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            let pending = _gateContinuations[index]
            _gateContinuations[index] = nil
            return pending
        }
        guard let continuation else { return }
        if lock.withLock({ _gateCancelled.contains(index) }) {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume()
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let index = lock.withLock { () -> Int in
            _requests.append(request)
            return _requests.count - 1
        }
        if isGated {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    lock.withLock { _gateContinuations[index] = continuation }
                }
            } onCancel: {
                let (shouldHold, continuation) = lock.withLock { () -> (Bool, CheckedContinuation<Void, Error>?) in
                    _gateCancelled.insert(index)
                    guard !_holdCancellations else { return (true, nil) }
                    let pending = _gateContinuations[index]
                    _gateContinuations[index] = nil
                    return (false, pending)
                }
                guard !shouldHold else { return }
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
