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

    private func executeRaw(_ sql: String, at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            throw MacomprendoError.dictationHistory("open raw history fixture")
        }
        defer { sqlite3_close_v2(database) }

        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw MacomprendoError.dictationHistory("execute raw history fixture")
        }
    }

    private func createSidecarSentinels(at databaseURL: URL) throws {
        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: databaseURL.path + suffix)
            guard FileManager.default.createFile(atPath: sidecarURL.path,
                                                 contents: Data("sentinel".utf8)) else {
                throw MacomprendoError.dictationHistory("create \(suffix) fixture")
            }
        }
    }

    private func createDatabaseWithDamagedHistoryTablePage(at databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            throw MacomprendoError.dictationHistory("create damaged-page fixture")
        }

        let schema = """
        CREATE TABLE dictation_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('dictation', 'dictationAndRefine')),
            text TEXT NOT NULL CHECK(length(trim(text)) > 0)
        );
        INSERT INTO dictation_history (created_at, kind, text)
        VALUES (1, 'dictation', 'before corruption');
        PRAGMA user_version = 1;
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close_v2(database)
            throw MacomprendoError.dictationHistory("seed damaged-page fixture")
        }

        func scalar(_ sql: String) throws -> Int64 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement
            else {
                throw MacomprendoError.dictationHistory("prepare damaged-page fixture metadata")
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw MacomprendoError.dictationHistory("read damaged-page fixture metadata")
            }
            return sqlite3_column_int64(statement, 0)
        }

        let pageSize = try scalar("PRAGMA page_size")
        let rootPage = try scalar(
            "SELECT rootpage FROM sqlite_master WHERE name = 'dictation_history'"
        )
        guard sqlite3_close_v2(database) == SQLITE_OK else {
            throw MacomprendoError.dictationHistory("close damaged-page fixture")
        }

        let file = try FileHandle(forWritingTo: databaseURL)
        defer { try? file.close() }
        try file.seek(toOffset: UInt64((rootPage - 1) * pageSize))
        try file.write(contentsOf: Data(repeating: 0, count: Int(pageSize)))
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

    // Catches binding or decoding SQLite text as a NUL-terminated C string, which truncates
    // otherwise-valid Swift text at U+0000.
    @Test func appendRoundTripsEmbeddedNULAndNonASCIIText() async throws {
        let (store, _) = makeStore()
        let text = "до\0после — 世界"

        _ = try await store.append(text: text, kind: .dictation, at: .now)

        let page = try await store.fetchPage(beforeID: nil, limit: 1)
        #expect(page.entries.map(\.text) == [text])
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

    // Catches committing the insert separately from retention trimming: an aborting trim must
    // roll the new row back and leave the pre-transaction history intact.
    @Test func trimFailureRollsBackTheInsertion() async throws {
        let (store, url) = makeStore(maximumEntryCount: 1)
        _ = try await store.append(text: "preserve me", kind: .dictation, at: .now)
        try executeRaw(
            """
            CREATE TRIGGER reject_history_trim
            BEFORE DELETE ON dictation_history
            BEGIN
                SELECT RAISE(ABORT, 'reject trim');
            END;
            """,
            at: url
        )

        do {
            _ = try await store.append(text: "must roll back", kind: .dictation, at: .now)
            Issue.record("expected retention trimming to abort the append transaction")
        } catch let error as MacomprendoError {
            guard case .dictationHistory = error else {
                Issue.record("expected a dictation history error, got \(error)")
                return
            }
        }

        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text)
                == ["preserve me"])
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

    // Catches recovery leaving stale WAL or SHM files beside a replaced future-schema database.
    @Test func clearRecoveryRemovesFutureSchemaSidecars() async throws {
        let (store, url) = makeStore()
        try setUserVersion(2, at: url)
        try createSidecarSentinels(at: url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: walURL.path))
        #expect(FileManager.default.fileExists(atPath: shmURL.path))

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
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: walURL.path))
        #expect(!FileManager.default.fileExists(atPath: shmURL.path))
        _ = try await store.append(text: "after reset", kind: .dictation, at: .now)
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text) == ["after reset"])
    }

    // Catches confirmed clear retrying DELETE forever on a cached connection after a table page
    // becomes corrupt, instead of using the promised destructive recovery path.
    @Test func clearRecoversAfterFetchCachesAPostOpenCorruption() async throws {
        let (store, url) = makeStore()
        try createDatabaseWithDamagedHistoryTablePage(at: url)

        do {
            _ = try await store.fetchPage(beforeID: nil, limit: 10)
            Issue.record("expected fetch to report the damaged table page")
        } catch let error as MacomprendoError {
            guard case .dictationHistory = error else {
                Issue.record("expected a dictation history error, got \(error)")
                return
            }
        }

        try await store.clear()
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.isEmpty)

        _ = try await store.append(text: "after recovery", kind: .dictation, at: .now)
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text)
                == ["after recovery"])
    }

    // Catches clear resetting a healthy database after a transactional delete failure.
    @Test func clearFailurePreservesRowsDatabaseAndSidecars() async throws {
        let (store, url) = makeStore()
        _ = try await store.append(text: "preserve me", kind: .dictation, at: .now)
        try executeRaw(
            """
            CREATE TRIGGER reject_history_clear
            BEFORE DELETE ON dictation_history
            BEGIN
                SELECT RAISE(ABORT, 'reject clear');
            END;
            """,
            at: url
        )
        try createSidecarSentinels(at: url)
        let walURL = URL(fileURLWithPath: url.path + "-wal")
        let shmURL = URL(fileURLWithPath: url.path + "-shm")

        do {
            try await store.clear()
            Issue.record("expected clear to report the aborting delete trigger")
        } catch let error as MacomprendoError {
            guard case .dictationHistory = error else {
                Issue.record("expected a dictation history error, got \(error)")
                return
            }
        }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: walURL.path))
        #expect(FileManager.default.fileExists(atPath: shmURL.path))
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text) == ["preserve me"])
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
