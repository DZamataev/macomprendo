import Foundation
@testable import Macomprendo

/// A `TranscriptStoring` that fails its next `create` once and forwards everything else to the
/// store it wraps — the row write launch recovery and the recorder have to survive without
/// losing the recording.
///
/// `FakeTranscriptStore` itself cannot fail a `create`: its `create` is non-throwing, and the
/// suites across the target call it without `try`. Making it `throws` would force a `try` into
/// every one of those call sites, so the one-shot failure lives in this decorator instead.
final class CreateFailingTranscriptStore: TranscriptStoring, @unchecked Sendable {
    private let inner: any TranscriptStoring
    private let lock = NSLock()
    private var pendingCreateFailure: MacomprendoError?

    init(wrapping inner: any TranscriptStoring) {
        self.inner = inner
    }

    /// Makes the next `create` throw, then clears itself.
    func failNextCreateOnce(_ error: MacomprendoError) {
        lock.withLock { pendingCreateFailure = error }
    }

    func create(sourceKind: TranscriptSourceKind, title: String, sourceBookmark: Data?,
                duration: TimeInterval?, run: TranscriptionRun, at: Date) async throws -> Int64 {
        let failure = lock.withLock {
            let pending = pendingCreateFailure
            pendingCreateFailure = nil
            return pending
        }
        if let failure { throw failure }
        return try await inner.create(sourceKind: sourceKind, title: title,
                                      sourceBookmark: sourceBookmark, duration: duration,
                                      run: run, at: at)
    }

    func appendSegment(_ segment: TranscriptSegment, to id: Int64) async throws {
        try await inner.appendSegment(segment, to: id)
    }

    func setStatus(_ status: TranscriptStatus, reason: String?, for id: Int64) async throws {
        try await inner.setStatus(status, reason: reason, for: id)
    }

    func setSummary(_ summary: String?, for id: Int64) async throws {
        try await inner.setSummary(summary, for: id)
    }

    func setSourceBookmark(_ bookmark: Data?, for id: Int64) async throws {
        try await inner.setSourceBookmark(bookmark, for: id)
    }

    func headers() async throws -> [TranscriptHeader] {
        try await inner.headers()
    }

    func transcript(id: Int64) async throws -> Transcript? {
        try await inner.transcript(id: id)
    }

    func delete(id: Int64) async throws {
        try await inner.delete(id: id)
    }

    func markAbandonedJobs(reason: String) async throws {
        try await inner.markAbandonedJobs(reason: reason)
    }
}
