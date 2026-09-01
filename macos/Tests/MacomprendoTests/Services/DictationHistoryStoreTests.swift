import Foundation
import SQLite3
import Testing
@testable import Macomprendo

@Suite struct DictationHistoryStoreTests {
    private func makeStore(maximumEntryCount: Int = 100_000)
        -> (SQLiteDictationHistoryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("history.sqlite3")
        return (SQLiteDictationHistoryStore(databaseURL: url,
                                            maximumEntryCount: maximumEntryCount), url)
    }

    private func setUserVersion(_ version: Int32, at databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            throw MacomprendoError.dictationHistory("create future-schema fixture")
        }
        defer { sqlite3_close_v2(database) }

        guard sqlite3_exec(database, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
            throw MacomprendoError.dictationHistory("set future-schema fixture version")
        }
    }

    // Catches using timestamp order, losing data across a reopen, or persisting the wrong kind.
    @Test func appendPersistsAcrossReopenAndFetchesNewestFirst() async throws {
        let (store, url) = makeStore()
        let first = try await store.append(text: "first", kind: .dictation,
                                           at: Date(timeIntervalSince1970: 1))
        let second = try await store.append(text: "second", kind: .dictationAndRefine,
                                            at: Date(timeIntervalSince1970: 2))
        #expect(first.id < second.id)

        let reopened = SQLiteDictationHistoryStore(databaseURL: url)
        let page = try await reopened.fetchPage(beforeID: nil, limit: 20)
        #expect(page.entries.map(\.text) == ["second", "first"])
        #expect(page.entries.map(\.kind) == [.dictationAndRefine, .dictation])
        #expect(page.nextCursor == nil)
    }

    // Catches including the cursor again, which would duplicate rows between pages.
    @Test func pagingUsesAnExclusiveInsertionCursor() async throws {
        let (store, _) = makeStore()
        for value in 1...5 {
            _ = try await store.append(text: "\(value)", kind: .dictation,
                                       at: Date(timeIntervalSince1970: 10))
        }
        let first = try await store.fetchPage(beforeID: nil, limit: 2)
        let second = try await store.fetchPage(beforeID: first.nextCursor, limit: 2)
        let third = try await store.fetchPage(beforeID: second.nextCursor, limit: 2)
        #expect(first.entries.map(\.text) == ["5", "4"])
        #expect(second.entries.map(\.text) == ["3", "2"])
        #expect(third.entries.map(\.text) == ["1"])
        #expect(third.nextCursor == nil)
    }

    // Catches treating zero or negative limits as valid page requests.
    @Test func fetchPageRejectsNonPositiveLimits() async throws {
        let (store, _) = makeStore()

        for limit in [0, -1] {
            do {
                _ = try await store.fetchPage(beforeID: nil, limit: limit)
                Issue.record("expected a dictation history error for limit \(limit)")
            } catch let error as MacomprendoError {
                guard case .dictationHistory = error else {
                    Issue.record("expected a dictation history error, got \(error)")
                    continue
                }
            }
        }
    }

    // Catches failing to create a missing parent directory before opening the database.
    @Test func openingStoreCreatesItsParentDirectory() async throws {
        let parentDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Macomprendo", isDirectory: true)
        let url = parentDirectory.appendingPathComponent("dictation-history.sqlite3")
        let store = SQLiteDictationHistoryStore(databaseURL: url)
        #expect(!FileManager.default.fileExists(atPath: parentDirectory.path))

        _ = try await store.fetchPage(beforeID: nil, limit: 1)

        #expect(FileManager.default.fileExists(atPath: parentDirectory.path))
    }

    // Catches retaining entries by timestamp rather than insertion ID, or trimming after commit.
    @Test func appendTrimsTheOldestEntryInTheSameCommit() async throws {
        let (store, _) = makeStore(maximumEntryCount: 3)
        for value in 1...4 {
            _ = try await store.append(text: "\(value)", kind: .dictation,
                                       at: Date(timeIntervalSince1970: Double(value)))
        }
        let page = try await store.fetchPage(beforeID: nil, limit: 10)
        #expect(page.entries.map(\.text) == ["4", "3", "2"])
        #expect(SQLiteDictationHistoryStore.defaultMaximumEntryCount == 100_000)
    }

    // Catches non-isolated connection access that drops rows during simultaneous writes.
    @Test func simultaneousAppendsLoseNoEntries() async throws {
        let (store, _) = makeStore(maximumEntryCount: 500)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<200 {
                group.addTask {
                    _ = try await store.append(text: "entry \(value)", kind: .dictation,
                                               at: Date(timeIntervalSince1970: Double(value)))
                }
            }
            try await group.waitForAll()
        }
        #expect(try await store.fetchPage(beforeID: nil, limit: 500).entries.count == 200)
    }

    // Catches clear leaving the store unable to accept and retrieve new entries.
    @Test func clearLeavesAnEmptyUsableStore() async throws {
        let (store, _) = makeStore()
        _ = try await store.append(text: "before clear", kind: .dictation, at: .now)

        try await store.clear()
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.isEmpty)

        let entry = try await store.append(text: "after clear", kind: .dictation, at: .now)
        #expect(entry.id == 1)
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text) == ["after clear"])
    }

    // Catches clear treating an already-empty store as an error.
    @Test func clearIsIdempotent() async throws {
        let (store, _) = makeStore()

        try await store.clear()
        try await store.clear()

        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.isEmpty)
    }

    // Catches clear failing permanently when an unsupported future schema prevents opening.
    @Test func clearResetsAnUnsupportedFutureSchema() async throws {
        let (store, url) = makeStore()
        try setUserVersion(2, at: url)

        do {
            _ = try await store.fetchPage(beforeID: nil, limit: 10)
            Issue.record("expected a history error for an unsupported schema")
        } catch let error as MacomprendoError {
            guard case .dictationHistory = error else {
                Issue.record("expected a dictation history error, got \(error)")
                return
            }
        }

        try await store.clear()
        _ = try await store.append(text: "after reset", kind: .dictation, at: .now)
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text) == ["after reset"])
    }

    // Catches allowing a retention configuration that deletes every appended row.
    @Test func appendRejectsANonPositiveMaximumEntryCount() async throws {
        let (store, _) = makeStore(maximumEntryCount: 0)

        do {
            _ = try await store.append(text: "entry", kind: .dictation, at: .now)
            Issue.record("expected a dictation history error for a non-positive maximum entry count")
        } catch let error as MacomprendoError {
            guard case .dictationHistory = error else {
                Issue.record("expected a dictation history error, got \(error)")
                return
            }
        }
    }
}
