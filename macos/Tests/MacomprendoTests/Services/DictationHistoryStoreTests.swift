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

    private func readUserVersion(at databaseURL: URL) throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else {
            throw MacomprendoError.dictationHistory("open history fixture for version read")
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw MacomprendoError.dictationHistory("prepare history fixture version read")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MacomprendoError.dictationHistory("read history fixture version")
        }
        return sqlite3_column_int(statement, 0)
    }

    private func createVersionOneDatabase(at databaseURL: URL, texts: [String]) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else {
            throw MacomprendoError.dictationHistory("create version-1 fixture")
        }
        defer { sqlite3_close_v2(database) }

        let inserts = texts.enumerated().map { index, text in
            "INSERT INTO dictation_history (created_at, kind, text) "
                + "VALUES (\(index + 1), 'dictation', '\(text)');"
        }.joined(separator: "\n")
        let schema = """
        CREATE TABLE dictation_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at REAL NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('dictation', 'dictationAndRefine')),
            text TEXT NOT NULL CHECK(length(trim(text)) > 0)
        );
        \(inserts)
        PRAGMA user_version = 1;
        """
        guard sqlite3_exec(database, schema, nil, nil, nil) == SQLITE_OK else {
            throw MacomprendoError.dictationHistory("seed version-1 fixture")
        }
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let permissions = attributes[.posixPermissions] as? NSNumber else {
            throw MacomprendoError.dictationHistory("read permissions of \(url.lastPathComponent)")
        }
        return permissions.intValue
    }

    @discardableResult
    private func writeAudioFile(named filename: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(filename)
        try Data("audio".utf8).write(to: url)
        return url
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
        try setUserVersion(3, at: url)
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

    // Catches a migration that recreates the table, drops rows, or leaves the version behind.
    @Test func versionOneDatabaseMigratesToVersionTwoKeepingEveryRow() async throws {
        let (store, url) = makeStore()
        try createVersionOneDatabase(at: url, texts: ["oldest", "middle", "newest"])
        #expect(try readUserVersion(at: url) == 1)

        let page = try await store.fetchPage(beforeID: nil, limit: 10)

        #expect(page.entries.map(\.text) == ["newest", "middle", "oldest"])
        #expect(page.entries.allSatisfy { $0.audioFileName == nil })
        #expect(try readUserVersion(at: url) == 2)

        _ = try await store.append(text: "after migration", kind: .dictation, at: .now)
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.count == 4)
    }

    // Catches attaching by row order rather than identifier, or dropping the column on read.
    @Test func attachedAudioFilenameSurvivesAReopenAndReadsBackThroughFetchPage() async throws {
        let (store, url) = makeStore()
        let first = try await store.append(text: "with audio", kind: .dictation,
                                           at: Date(timeIntervalSince1970: 1))
        _ = try await store.append(text: "without audio", kind: .dictation,
                                   at: Date(timeIntervalSince1970: 2))

        try await store.attachAudioFile(named: "\(first.id).m4a", toEntry: first.id)

        let reopened = SQLiteDictationHistoryStore(databaseURL: url)
        let page = try await reopened.fetchPage(beforeID: nil, limit: 10)
        #expect(page.entries.map(\.text) == ["without audio", "with audio"])
        #expect(page.entries.map(\.audioFileName) == [nil, "\(first.id).m4a"])
        #expect(try await reopened.referencedAudioFilenames() == ["\(first.id).m4a"])
    }

    // Catches attaching to an identifier that no longer exists, which would silently succeed.
    @Test func attachingToAnUnknownEntryReportsAnError() async throws {
        let (store, _) = makeStore()

        do {
            try await store.attachAudioFile(named: "404.m4a", toEntry: 404)
            Issue.record("expected a dictation history error for an unknown entry")
        } catch let error as MacomprendoError {
            guard case .dictationHistory = error else {
                Issue.record("expected a dictation history error, got \(error)")
                return
            }
        }
    }

    // Catches an age cutoff that is inclusive on the wrong side, or that forgets to report the
    // filenames the caller must delete from disk.
    @Test func deletingEntriesOlderThanACutoffReportsOnlyTheirAudioFilenames() async throws {
        let (store, _) = makeStore()
        let old = try await store.append(text: "old", kind: .dictation,
                                         at: Date(timeIntervalSince1970: 100))
        let alsoOld = try await store.append(text: "also old", kind: .dictation,
                                             at: Date(timeIntervalSince1970: 200))
        let recent = try await store.append(text: "recent", kind: .dictation,
                                            at: Date(timeIntervalSince1970: 400))
        try await store.attachAudioFile(named: "old.m4a", toEntry: old.id)
        try await store.attachAudioFile(named: "recent.m4a", toEntry: recent.id)
        #expect(alsoOld.id > old.id)

        let orphaned = try await store.deleteEntries(olderThan: Date(timeIntervalSince1970: 300))

        #expect(orphaned == ["old.m4a"])
        let page = try await store.fetchPage(beforeID: nil, limit: 10)
        #expect(page.entries.map(\.text) == ["recent"])
        #expect(page.entries.map(\.audioFileName) == ["recent.m4a"])
        #expect(try await store.referencedAudioFilenames() == ["recent.m4a"])
    }

    // Catches an entry exactly on the cutoff being deleted: the cutoff is the oldest age kept.
    @Test func deletingEntriesOlderThanACutoffKeepsAnEntryExactlyOnIt() async throws {
        let (store, _) = makeStore()
        _ = try await store.append(text: "on the cutoff", kind: .dictation,
                                   at: Date(timeIntervalSince1970: 300))

        let orphaned = try await store.deleteEntries(olderThan: Date(timeIntervalSince1970: 300))

        #expect(orphaned.isEmpty)
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.map(\.text)
                == ["on the cutoff"])
    }

    // Catches "Delete saved audio" deleting rows along with the references it clears.
    @Test func deletingAudioReferencesKeepsEveryTranscript() async throws {
        let (store, _) = makeStore()
        let first = try await store.append(text: "first", kind: .dictation,
                                           at: Date(timeIntervalSince1970: 1))
        let second = try await store.append(text: "second", kind: .dictationAndRefine,
                                            at: Date(timeIntervalSince1970: 2))
        try await store.attachAudioFile(named: "first.m4a", toEntry: first.id)
        try await store.attachAudioFile(named: "second.m4a", toEntry: second.id)

        let orphaned = try await store.deleteAudioReferences()

        #expect(orphaned.sorted() == ["first.m4a", "second.m4a"])
        let page = try await store.fetchPage(beforeID: nil, limit: 10)
        #expect(page.entries.map(\.text) == ["second", "first"])
        #expect(page.entries.map(\.audioFileName) == [nil, nil])
        #expect(try await store.referencedAudioFilenames().isEmpty)
    }

    // Catches Clear History leaving recordings on disk behind the transcripts it removed.
    @Test func clearRemovesEveryRecordingFromTheAudioDirectory() async throws {
        let (store, _) = makeStore()
        let entry = try await store.append(text: "with audio", kind: .dictation, at: .now)
        let directory = store.audioDirectoryURL
        try await store.attachAudioFile(named: "\(entry.id).m4a", toEntry: entry.id)
        try writeAudioFile(named: "\(entry.id).m4a", in: directory)
        let orphanURL = try writeAudioFile(named: "orphan.m4a", in: directory)

        try await store.clear()

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try await store.fetchPage(beforeID: nil, limit: 10).entries.isEmpty)
    }

    // Catches Clear History racing an in-flight recording encode: the encoder writes the
    // file to the audio directory outside the actor, so `clear()` must wait for any write it
    // was told about before it empties the directory, or the file that lands afterwards
    // survives a clear that documents "no recording behind".
    @Test func clearWaitsForAnInFlightAudioWriteBeforeEmptyingTheDirectory() async throws {
        let (store, _) = makeStore()
        _ = try await store.fetchPage(beforeID: nil, limit: 1)
        let directory = store.audioDirectoryURL
        await store.beginAudioWrite()

        let clearTask = Task { try await store.clear() }

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await store.isWaitingForAudioWrites { break }
            await Task.yield()
        }
        #expect(await store.isWaitingForAudioWrites)

        // Simulate the encoder finishing its write while `clear()` is blocked on it.
        try writeAudioFile(named: "late.m4a", in: directory)
        await store.endAudioWrite()
        try await clearTask.value

        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("late.m4a").path))
    }

    // Catches the support and audio directories being created with the default group- and
    // world-readable mode, which would expose recordings to a second account on the same Mac.
    @Test func theSupportAndAudioDirectoriesAreOwnerOnly() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Macomprendo", isDirectory: true)
        let store = SQLiteDictationHistoryStore(
            databaseURL: supportDirectory.appendingPathComponent("dictation-history.sqlite3")
        )

        _ = try await store.fetchPage(beforeID: nil, limit: 1)

        let audioDirectory = store.audioDirectoryURL
        #expect(audioDirectory == supportDirectory.appendingPathComponent("dictation-audio",
                                                                         isDirectory: true))
        #expect(try permissions(of: supportDirectory) == 0o700)
        #expect(try permissions(of: audioDirectory) == 0o700)
    }

    // Catches tightening permissions only on directories `createDirectory` actually created:
    // an upgraded install already has the support directory at the default 0o755, and
    // `createDirectory` leaves an existing directory's mode untouched, so the fresh-install
    // test above cannot see this path.
    @Test func anAlreadyExistingSupportDirectoryIsTightenedOnOpen() async throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Macomprendo", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        #expect(try permissions(of: supportDirectory) == 0o755)
        let store = SQLiteDictationHistoryStore(
            databaseURL: supportDirectory.appendingPathComponent("dictation-history.sqlite3")
        )

        _ = try await store.fetchPage(beforeID: nil, limit: 1)

        #expect(try permissions(of: supportDirectory) == 0o700)
        #expect(try permissions(of: store.audioDirectoryURL) == 0o700)
    }

    // Catches treating a populated audio_file whose file vanished as corruption: the entry must
    // still be returned, keeping the transcript readable.
    @Test func anEntryWhoseAudioFileIsMissingIsStillReturned() async throws {
        let (store, _) = makeStore()
        let entry = try await store.append(text: "audio deleted underneath us", kind: .dictation,
                                           at: .now)
        try await store.attachAudioFile(named: "\(entry.id).m4a", toEntry: entry.id)
        let directory = store.audioDirectoryURL
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("\(entry.id).m4a").path
        ))

        let page = try await store.fetchPage(beforeID: nil, limit: 10)

        #expect(page.entries.map(\.text) == ["audio deleted underneath us"])
        #expect(page.entries.map(\.audioFileName) == ["\(entry.id).m4a"])
        #expect(try await store.referencedAudioFilenames() == ["\(entry.id).m4a"])
    }

    // Catches a size readout that counts nothing, counts the directory entry itself, or throws
    // on a directory that does not exist yet.
    @Test func theAudioDirectoryByteCountSumsTheFilesPresent() async throws {
        let (store, _) = makeStore()
        _ = try await store.fetchPage(beforeID: nil, limit: 1)
        let directory = store.audioDirectoryURL

        #expect(try await store.audioDirectoryByteCount() == 0)

        try writeAudioFile(named: "one.m4a", in: directory)
        try writeAudioFile(named: "two.m4a", in: directory)

        #expect(try await store.audioDirectoryByteCount() == Int64("audio".utf8.count * 2))
    }

    // Catches listing referenced names instead of the files that are actually on disk.
    @Test func existingAudioFilenamesListsWhatIsOnDiskNotWhatIsReferenced() async throws {
        let (store, _) = makeStore()
        let entry = try await store.append(text: "gone", kind: .dictation, at: .now)
        try await store.attachAudioFile(named: "\(entry.id).m4a", toEntry: entry.id)
        try writeAudioFile(named: "orphan.m4a", in: store.audioDirectoryURL)

        #expect(try await store.existingAudioFilenames() == ["orphan.m4a"])
    }

    // Catches reading a vanished recording as an error rather than as "no recording".
    @Test func audioFileDataReturnsTheBytesOrNilWhenTheFileIsGone() async throws {
        let (store, _) = makeStore()
        _ = try await store.fetchPage(beforeID: nil, limit: 1)
        try writeAudioFile(named: "present.m4a", in: store.audioDirectoryURL)

        #expect(try await store.audioFileData(named: "present.m4a") == Data("audio".utf8))
        #expect(try await store.audioFileData(named: "missing.m4a") == nil)
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
