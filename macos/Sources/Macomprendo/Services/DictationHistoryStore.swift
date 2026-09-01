import Foundation
import SQLite3

protocol DictationHistoryStoring: Sendable {
    func append(text: String, kind: DictationHistoryKind, at: Date) async throws
        -> DictationHistoryEntry
    func fetchPage(beforeID: Int64?, limit: Int) async throws -> DictationHistoryPage
    func clear() async throws
}

actor SQLiteDictationHistoryStore: DictationHistoryStoring {
    static let defaultMaximumEntryCount = 100_000

    private let databaseURL: URL
    private let maximumEntryCount: Int
    private var database: DatabaseHandle?

    init(databaseURL: URL,
         maximumEntryCount: Int = SQLiteDictationHistoryStore.defaultMaximumEntryCount) {
        self.databaseURL = databaseURL
        self.maximumEntryCount = maximumEntryCount
    }

    func append(text: String, kind: DictationHistoryKind, at: Date) throws
        -> DictationHistoryEntry {
        guard maximumEntryCount > 0 else {
            throw MacomprendoError.dictationHistory("append: maximum entry count must be positive")
        }

        let database = try connection()
        try execute("BEGIN IMMEDIATE", on: database, operation: "begin append")

        do {
            let statement = try prepare(
                "INSERT INTO dictation_history (created_at, kind, text) VALUES (?1, ?2, ?3)",
                on: database,
                operation: "prepare append"
            )
            defer { sqlite3_finalize(statement) }

            try check(sqlite3_bind_double(statement, 1, at.timeIntervalSince1970),
                      on: database, operation: "bind append date")
            try bind(kind.rawValue, to: statement, index: 2, on: database, operation: "bind append kind")
            try bind(text, to: statement, index: 3, on: database, operation: "bind append text")
            try check(sqlite3_step(statement), expected: SQLITE_DONE, on: database, operation: "append entry")

            try trimRetention(on: database)
            try execute("COMMIT", on: database, operation: "commit append")

            return DictationHistoryEntry(id: sqlite3_last_insert_rowid(database),
                                         createdAt: at, kind: kind, text: text)
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func fetchPage(beforeID: Int64?, limit: Int) throws -> DictationHistoryPage {
        guard limit > 0 else {
            throw MacomprendoError.dictationHistory("fetch page: limit must be positive")
        }

        let database = try connection()
        let statement = try prepare(
            """
            SELECT id, created_at, kind, text
            FROM dictation_history
            WHERE (?1 IS NULL OR id < ?1)
            ORDER BY id DESC
            LIMIT ?2
            """,
            on: database,
            operation: "prepare fetch page"
        )
        defer { sqlite3_finalize(statement) }

        if let beforeID {
            try check(sqlite3_bind_int64(statement, 1, beforeID),
                      on: database, operation: "bind page cursor")
        } else {
            try check(sqlite3_bind_null(statement, 1), on: database, operation: "bind page cursor")
        }
        try check(sqlite3_bind_int64(statement, 2, Int64(limit) + 1),
                  on: database, operation: "bind page limit")

        var entries: [DictationHistoryEntry] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try check(result, expected: SQLITE_ROW, on: database, operation: "fetch page")

            guard let kindValue = sqlite3_column_text(statement, 2),
                  let kind = DictationHistoryKind(rawValue: String(cString: kindValue)),
                  let textValue = sqlite3_column_text(statement, 3)
            else {
                throw MacomprendoError.dictationHistory("fetch page: invalid stored entry")
            }

            entries.append(DictationHistoryEntry(
                id: sqlite3_column_int64(statement, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: kind,
                text: String(cString: textValue)
            ))
        }

        let hasMore = entries.count > limit
        let pageEntries = Array(entries.prefix(limit))
        return DictationHistoryPage(entries: pageEntries,
                                    nextCursor: hasMore ? pageEntries.last?.id : nil)
    }

    func clear() throws {
        let activeDatabase: OpaquePointer
        if let existingDatabase = database {
            activeDatabase = existingDatabase.pointer
        } else {
            do {
                activeDatabase = try connection()
            } catch {
                try resetDatabase()
                return
            }
        }

        try execute("BEGIN IMMEDIATE", on: activeDatabase, operation: "begin clear history")
        do {
            try execute("DELETE FROM dictation_history", on: activeDatabase, operation: "clear history")
            try execute("DELETE FROM sqlite_sequence WHERE name = 'dictation_history'",
                        on: activeDatabase, operation: "reset history sequence")
            try execute("COMMIT", on: activeDatabase, operation: "commit clear history")
        } catch {
            sqlite3_exec(activeDatabase, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func resetDatabase() throws {
        database = nil
        let sidecarURLs = [databaseURL,
                           URL(fileURLWithPath: databaseURL.path + "-wal"),
                           URL(fileURLWithPath: databaseURL.path + "-shm")]
        for url in sidecarURLs where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw MacomprendoError.dictationHistory("reset database: \(error.localizedDescription)")
            }
        }
        _ = try connection()
    }

    private func connection() throws -> OpaquePointer {
        if let database { return database.pointer }

        let parentDirectory = databaseURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDirectory,
                                                    withIntermediateDirectories: true)
        } catch {
            throw MacomprendoError.dictationHistory("create database directory: \(error.localizedDescription)")
        }

        var openedDatabase: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &openedDatabase, flags, nil)
        guard result == SQLITE_OK, let openedDatabase else {
            let message = sqliteMessage(from: openedDatabase)
            if let openedDatabase { sqlite3_close_v2(openedDatabase) }
            throw MacomprendoError.dictationHistory("open database: \(message)")
        }

        do {
            try execute("PRAGMA foreign_keys = ON", on: openedDatabase, operation: "enable foreign keys")
            let version = try userVersion(on: openedDatabase)
            guard version == 0 || version == 1 else {
                throw MacomprendoError.dictationHistory("open database: unsupported schema version \(version)")
            }
            if version == 0 {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS dictation_history (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        created_at REAL NOT NULL,
                        kind TEXT NOT NULL CHECK(kind IN ('dictation', 'dictationAndRefine')),
                        text TEXT NOT NULL CHECK(length(trim(text)) > 0)
                    );
                    PRAGMA user_version = 1;
                    """,
                    on: openedDatabase,
                    operation: "create history schema"
                )
            }
            database = DatabaseHandle(openedDatabase)
            return openedDatabase
        } catch {
            sqlite3_close_v2(openedDatabase)
            throw error
        }
    }

    private func userVersion(on database: OpaquePointer) throws -> Int32 {
        let statement = try prepare("PRAGMA user_version", on: database, operation: "read schema version")
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_step(statement), expected: SQLITE_ROW, on: database, operation: "read schema version")
        return sqlite3_column_int(statement, 0)
    }

    private func trimRetention(on database: OpaquePointer) throws {
        let statement = try prepare(
            """
            DELETE FROM dictation_history
            WHERE id NOT IN (
                SELECT id FROM dictation_history ORDER BY id DESC LIMIT ?1
            )
            """,
            on: database,
            operation: "prepare trim history"
        )
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, Int64(maximumEntryCount)),
                  on: database, operation: "bind history retention")
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: database, operation: "trim history")
    }

    private func execute(_ sql: String, on database: OpaquePointer, operation: String) throws {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        try check(result, on: database, operation: operation)
    }

    private func prepare(_ sql: String, on database: OpaquePointer, operation: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        try check(result, on: database, operation: operation)
        guard let statement else {
            throw MacomprendoError.dictationHistory("\(operation): no statement returned")
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32,
                      on database: OpaquePointer, operation: String) throws {
        let destructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, index, value, -1, destructor),
                  on: database, operation: operation)
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK,
                       on database: OpaquePointer?, operation: String) throws {
        guard result == expected else {
            throw MacomprendoError.dictationHistory("\(operation): \(sqliteMessage(from: database))")
        }
    }

    private func sqliteMessage(from database: OpaquePointer?) -> String {
        guard let database, let message = sqlite3_errmsg(database) else {
            return "unknown SQLite error"
        }
        return String(cString: message)
    }
}

private final class DatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}
