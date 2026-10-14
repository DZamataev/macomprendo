import Foundation
import Testing
@testable import Macomprendo

@Suite struct TranscriptStoreTests {
    private let run = TranscriptionRun(modelID: "base", engine: "whisperCpp", language: "ru",
                                       appVersion: "1.2.3")

    private func makeStore() -> (SQLiteTranscriptStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcripts-\(UUID().uuidString)", isDirectory: true)
        return (SQLiteTranscriptStore(databaseURL: directory.appendingPathComponent("t.sqlite3")),
                directory)
    }

    @Test func aCreatedTranscriptReadsBackWithItsSegmentsInOrder() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = try await store.create(sourceKind: .file, title: "talk.m4a",
                                        sourceBookmark: Data([1, 2, 3]), duration: 61.5,
                                        run: run, at: Date(timeIntervalSince1970: 1000))
        try await store.appendSegment(TranscriptSegment(start: 0.5, end: 3, text: "One."), to: id)
        try await store.appendSegment(
            TranscriptSegment(start: 4, end: 9, text: "Two pytest.", rawText: "Two пайтест."),
            to: id)

        let transcript = try #require(try await store.transcript(id: id))
        #expect(transcript.header == TranscriptHeader(
            id: id, createdAt: Date(timeIntervalSince1970: 1000), sourceKind: .file,
            title: "talk.m4a", duration: 61.5, status: .inProgress, statusReason: nil))
        #expect(transcript.run == run)
        #expect(transcript.sourceBookmark == Data([1, 2, 3]))
        #expect(transcript.summary == nil)
        #expect(transcript.segments == [
            TranscriptSegment(start: 0.5, end: 3, text: "One."),
            TranscriptSegment(start: 4, end: 9, text: "Two pytest.", rawText: "Two пайтест."),
        ])
    }

    @Test func statusAndReasonTransition() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "a", sourceBookmark: nil,
                                        duration: nil, run: run, at: .now)

        try await store.setStatus(.incomplete, reason: "Cancelled.", for: id)
        var header = try #require(try await store.headers().first)
        #expect(header.status == .incomplete)
        #expect(header.statusReason == "Cancelled.")
        #expect(header.duration == nil)

        // A reason is meaningless for any other status and is not kept.
        try await store.setStatus(.complete, reason: "ignored", for: id)
        header = try #require(try await store.headers().first)
        #expect(header.status == .complete)
        #expect(header.statusReason == nil)
    }

    @Test func headersAreNewestFirst() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        for title in ["first", "second", "third"] {
            _ = try await store.create(sourceKind: .file, title: title, sourceBookmark: nil,
                                       duration: 1, run: run, at: .now)
        }
        #expect(try await store.headers().map(\.title) == ["third", "second", "first"])
    }

    @Test func summaryIsStoredAndCleared() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "a", sourceBookmark: nil,
                                        duration: 1, run: run, at: .now)
        try await store.setSummary("In short.", for: id)
        #expect(try await store.transcript(id: id)?.summary == "In short.")
        try await store.setSummary(nil, for: id)
        #expect(try await store.transcript(id: id)?.summary == nil)
    }

    @Test func deletingATranscriptDeletesItsSegments() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "a", sourceBookmark: nil,
                                        duration: 1, run: run, at: .now)
        try await store.appendSegment(TranscriptSegment(start: 0, end: 1, text: "x"), to: id)
        try await store.delete(id: id)
        #expect(try await store.transcript(id: id) == nil)
        #expect(try await store.headers().isEmpty)

        // A new transcript never inherits the deleted one's segments.
        let next = try await store.create(sourceKind: .file, title: "b", sourceBookmark: nil,
                                          duration: 1, run: run, at: .now)
        #expect(try await store.transcript(id: next)?.segments.isEmpty == true)
    }

    @Test func abandonedJobsBecomeIncompleteAndFinishedOnesStay() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let running = try await store.create(sourceKind: .file, title: "running",
                                             sourceBookmark: nil, duration: 1, run: run, at: .now)
        let done = try await store.create(sourceKind: .file, title: "done",
                                          sourceBookmark: nil, duration: 1, run: run, at: .now)
        try await store.setStatus(.complete, reason: nil, for: done)

        try await store.markAbandonedJobs(reason: "Macomprendo quit before it finished.")

        #expect(try await store.transcript(id: running)?.header.status == .incomplete)
        #expect(try await store.transcript(id: running)?.header.statusReason
                == "Macomprendo quit before it finished.")
        #expect(try await store.transcript(id: done)?.header.status == .complete)
    }

    @Test func updatingAMissingTranscriptIsAnError() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        await #expect(throws: MacomprendoError.transcriptStore("no transcript has identifier 42")) {
            try await store.setStatus(.complete, reason: nil, for: 42)
        }
    }

    @Test func aSecondStoreOnTheSameFileSeesTheData() async throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = try await store.create(sourceKind: .file, title: "kept", sourceBookmark: nil,
                                        duration: 1, run: run, at: .now)
        let reopened = SQLiteTranscriptStore(
            databaseURL: directory.appendingPathComponent("t.sqlite3"))
        #expect(try await reopened.transcript(id: id)?.header.title == "kept")
    }
}
