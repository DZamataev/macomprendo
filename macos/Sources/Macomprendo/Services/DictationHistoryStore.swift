import Foundation
import SQLite3

protocol DictationHistoryStoring: Sendable {
    /// The directory holding one recording per entry, named after the entry identifier.
    var audioDirectoryURL: URL { get }

    func append(text: String, kind: DictationHistoryKind, at: Date) async throws
        -> DictationHistoryEntry
    func fetchPage(beforeID: Int64?, limit: Int) async throws -> DictationHistoryPage

    /// Removes every entry and, unlike the operations below, also deletes every file in the
    /// audio directory — including files no entry references — so a cleared history leaves no
    /// recording behind. The directory itself stays.
    func clear() async throws

    /// Records `filename` as the recording of an existing entry. Reports an error when no entry
    /// carries that identifier, so a lost row never leaves a file unreferenced silently.
    func attachAudioFile(named filename: String, toEntry id: Int64) async throws

    /// Deletes every entry created strictly before `cutoff` and returns the audio filenames
    /// those entries referenced, which the caller deletes from the audio directory.
    @discardableResult
    func deleteEntries(olderThan cutoff: Date) async throws -> [String]

    /// Clears every audio reference and keeps every transcript, returning the filenames that
    /// were referenced so the caller deletes them from the audio directory.
    @discardableResult
    func deleteAudioReferences() async throws -> [String]

    /// Every audio filename currently referenced by an entry, so unreferenced files can be found.
    func referencedAudioFilenames() async throws -> [String]

    /// Removes the named files if present. Missing files are tolerated.
    func removeAudioFiles(named filenames: [String]) async throws

    /// Removes every file in the audio directory not present in `referencedFilenames`.
    func purgeUnreferencedAudioFiles(keeping referencedFilenames: Set<String>) async throws
}

actor SQLiteDictationHistoryStore: DictationHistoryStoring {
    static let defaultMaximumEntryCount = 100_000

    private let databaseURL: URL
    private let maximumEntryCount: Int
    private var database: DatabaseHandle?
    private var requiresConfirmedReset = false

    nonisolated let audioDirectoryURL: URL

    init(databaseURL: URL,
         maximumEntryCount: Int = SQLiteDictationHistoryStore.defaultMaximumEntryCount) {
        self.databaseURL = databaseURL
        self.maximumEntryCount = maximumEntryCount
        self.audioDirectoryURL = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("dictation-audio", isDirectory: true)
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
            SELECT id, created_at, kind, text, audio_file
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

            guard let kindValue = text(from: statement, index: 2),
                  let kind = DictationHistoryKind(rawValue: kindValue),
                  let textValue = text(from: statement, index: 3)
            else {
                throw MacomprendoError.dictationHistory("fetch page: invalid stored entry")
            }

            entries.append(DictationHistoryEntry(
                id: sqlite3_column_int64(statement, 0),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                kind: kind,
                text: textValue,
                audioFileName: text(from: statement, index: 4)
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
                guard requiresConfirmedReset else { throw error }
                try resetDatabase()
                try removeEveryAudioFile()
                return
            }
        }

        do {
            try execute("BEGIN IMMEDIATE", on: activeDatabase, operation: "begin clear history")
            try execute("DELETE FROM dictation_history", on: activeDatabase, operation: "clear history")
            try execute("DELETE FROM sqlite_sequence WHERE name = 'dictation_history'",
                        on: activeDatabase, operation: "reset history sequence")
            try execute("COMMIT", on: activeDatabase, operation: "commit clear history")
        } catch {
            let result = sqlite3_extended_errcode(activeDatabase)
            sqlite3_exec(activeDatabase, "ROLLBACK", nil, nil, nil)
            if isCorruption(result) {
                try resetDatabase()
                try removeEveryAudioFile()
                return
            }
            throw error
        }

        try removeEveryAudioFile()
    }

    func attachAudioFile(named filename: String, toEntry id: Int64) throws {
        let database = try connection()
        let statement = try prepare("UPDATE dictation_history SET audio_file = ?1 WHERE id = ?2",
                                    on: database, operation: "prepare attach audio file")
        defer { sqlite3_finalize(statement) }

        try bind(filename, to: statement, index: 1, on: database, operation: "bind audio filename")
        try check(sqlite3_bind_int64(statement, 2, id), on: database, operation: "bind audio entry id")
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: database,
                  operation: "attach audio file")
        guard sqlite3_changes(database) == 1 else {
            throw MacomprendoError.dictationHistory("attach audio file: no entry with id \(id)")
        }
    }

    @discardableResult
    func deleteEntries(olderThan cutoff: Date) throws -> [String] {
        let database = try connection()
        try execute("BEGIN IMMEDIATE", on: database, operation: "begin age retention")

        do {
            let filenames = try audioFilenames(
                """
                SELECT audio_file FROM dictation_history
                WHERE created_at < ?1 AND audio_file IS NOT NULL
                ORDER BY id ASC
                """,
                on: database,
                operation: "read expiring audio filenames",
                bindDouble: cutoff.timeIntervalSince1970
            )

            let statement = try prepare("DELETE FROM dictation_history WHERE created_at < ?1",
                                        on: database, operation: "prepare age retention")
            defer { sqlite3_finalize(statement) }
            try check(sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970),
                      on: database, operation: "bind age retention cutoff")
            try check(sqlite3_step(statement), expected: SQLITE_DONE, on: database,
                      operation: "apply age retention")

            try execute("COMMIT", on: database, operation: "commit age retention")
            return filenames
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    @discardableResult
    func deleteAudioReferences() throws -> [String] {
        let database = try connection()
        try execute("BEGIN IMMEDIATE", on: database, operation: "begin delete audio references")

        do {
            let filenames = try audioFilenames(
                "SELECT audio_file FROM dictation_history WHERE audio_file IS NOT NULL ORDER BY id ASC",
                on: database,
                operation: "read audio filenames"
            )
            try execute("UPDATE dictation_history SET audio_file = NULL WHERE audio_file IS NOT NULL",
                        on: database, operation: "delete audio references")
            try execute("COMMIT", on: database, operation: "commit delete audio references")
            return filenames
        } catch {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func referencedAudioFilenames() throws -> [String] {
        let database = try connection()
        return try audioFilenames(
            "SELECT audio_file FROM dictation_history WHERE audio_file IS NOT NULL ORDER BY id ASC",
            on: database,
            operation: "list referenced audio filenames"
        )
    }

    func removeAudioFiles(named filenames: [String]) throws {
        for filename in filenames {
            let url = audioDirectoryURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw MacomprendoError.dictationHistory(
                    "remove saved recording: \(error.localizedDescription)"
                )
            }
        }
    }

    func purgeUnreferencedAudioFiles(keeping referencedFilenames: Set<String>) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: audioDirectoryURL.path) else { return }
        do {
            for url in try manager.contentsOfDirectory(at: audioDirectoryURL,
                                                       includingPropertiesForKeys: nil)
                where !referencedFilenames.contains(url.lastPathComponent) {
                try manager.removeItem(at: url)
            }
        } catch {
            throw MacomprendoError.dictationHistory(
                "purge unreferenced recordings: \(error.localizedDescription)"
            )
        }
    }

    private func audioFilenames(_ sql: String, on database: OpaquePointer, operation: String,
                                bindDouble: Double? = nil) throws -> [String] {
        let statement = try prepare(sql, on: database, operation: "prepare \(operation)")
        defer { sqlite3_finalize(statement) }
        if let bindDouble {
            try check(sqlite3_bind_double(statement, 1, bindDouble),
                      on: database, operation: "bind \(operation)")
        }

        var filenames: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            try check(result, expected: SQLITE_ROW, on: database, operation: operation)
            guard let filename = text(from: statement, index: 0) else {
                throw MacomprendoError.dictationHistory("\(operation): invalid stored audio filename")
            }
            filenames.append(filename)
        }
        return filenames
    }

    /// Empties the audio directory, including files no entry references, so a cleared history
    /// leaves nothing behind even after a crash orphaned a recording.
    private func removeEveryAudioFile() throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: audioDirectoryURL.path) else { return }
        do {
            for url in try manager.contentsOfDirectory(at: audioDirectoryURL,
                                                       includingPropertiesForKeys: nil) {
                try manager.removeItem(at: url)
            }
        } catch {
            throw MacomprendoError.dictationHistory(
                "remove saved recordings: \(error.localizedDescription)"
            )
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
        requiresConfirmedReset = false

        let parentDirectory = databaseURL.deletingLastPathComponent()
        // Owner-only: this keeps a second account on the same Mac out. The app is deliberately
        // unsandboxed (ADR-0003), so any process running as this user still reads these files.
        for directory in [parentDirectory, audioDirectoryURL] {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw MacomprendoError.dictationHistory(
                    "create database directory: \(error.localizedDescription)"
                )
            }
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
            guard version >= 0 && version <= 2 else {
                requiresConfirmedReset = true
                throw MacomprendoError.dictationHistory("open database: unsupported schema version \(version)")
            }
            if version == 0 {
                try execute(
                    """
                    CREATE TABLE IF NOT EXISTS dictation_history (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        created_at REAL NOT NULL,
                        kind TEXT NOT NULL CHECK(kind IN ('dictation', 'dictationAndRefine')),
                        text TEXT NOT NULL CHECK(length(trim(text)) > 0),
                        audio_file TEXT
                    );
                    PRAGMA user_version = 2;
                    """,
                    on: openedDatabase,
                    operation: "create history schema"
                )
            } else if version == 1 {
                // Adds the column in place, leaving every existing row untouched with a NULL
                // reference, which reads as "no recording was ever saved".
                try execute(
                    """
                    ALTER TABLE dictation_history ADD COLUMN audio_file TEXT;
                    PRAGMA user_version = 2;
                    """,
                    on: openedDatabase,
                    operation: "migrate history schema to version 2"
                )
            }
            database = DatabaseHandle(openedDatabase)
            return openedDatabase
        } catch {
            if isCorruption(sqlite3_extended_errcode(openedDatabase)) {
                requiresConfirmedReset = true
            }
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
        let result = value.utf8CString.withUnsafeBufferPointer { bytes in
            sqlite3_bind_text64(statement, index, bytes.baseAddress,
                                UInt64(bytes.count - 1), destructor, UInt8(SQLITE_UTF8))
        }
        try check(result, on: database, operation: operation)
    }

    private func text(from statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index)
        else { return nil }

        let bytes = UnsafeBufferPointer(start: value,
                                        count: Int(sqlite3_column_bytes(statement, index)))
        return String(bytes: bytes, encoding: .utf8)
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK,
                       on database: OpaquePointer?, operation: String) throws {
        guard result == expected else {
            throw MacomprendoError.dictationHistory("\(operation): \(sqliteMessage(from: database))")
        }
    }

    private func isCorruption(_ result: Int32) -> Bool {
        let primaryResult = result & 0xff
        return primaryResult == SQLITE_CORRUPT || primaryResult == SQLITE_NOTADB
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
