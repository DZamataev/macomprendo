import Foundation
import SQLite3

protocol TranscriptStoring: Sendable {
    /// Creates an `inProgress` transcript and returns its identifier.
    func create(sourceKind: TranscriptSourceKind, title: String, sourceBookmark: Data?,
                duration: TimeInterval?, run: TranscriptionRun, at: Date) async throws -> Int64
    func appendSegment(_ segment: TranscriptSegment, to id: Int64) async throws
    /// `reason` is stored only for `incomplete`, and must hold no transcript text.
    func setStatus(_ status: TranscriptStatus, reason: String?, for id: Int64) async throws
    func setSummary(_ summary: String?, for id: Int64) async throws
    /// Every transcript, newest first.
    func headers() async throws -> [TranscriptHeader]
    func transcript(id: Int64) async throws -> Transcript?
    func delete(id: Int64) async throws
    /// Turns every `inProgress` transcript into `incomplete`. Called once at launch, when no
    /// job can be running, so any `inProgress` row belongs to a job the app did not finish.
    func markAbandonedJobs(reason: String) async throws
}

/// Transcripts in their own database, apart from dictation history (ADR-0016).
actor SQLiteTranscriptStore: TranscriptStoring {
    private let databaseURL: URL
    private var handle: TranscriptDatabaseHandle?

    init(databaseURL: URL) {
        self.databaseURL = databaseURL
    }

    func create(sourceKind: TranscriptSourceKind, title: String, sourceBookmark: Data?,
                duration: TimeInterval?, run: TranscriptionRun, at: Date) throws -> Int64 {
        let db = try connection()
        let statement = try prepare("""
            INSERT INTO transcripts
                (created_at, source_kind, title, source_bookmark, duration_s, status,
                 model_id, engine, language, app_version)
            VALUES (?1, ?2, ?3, ?4, ?5, 'inProgress', ?6, ?7, ?8, ?9)
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_double(statement, 1, at.timeIntervalSince1970), on: db)
        try bind(sourceKind.rawValue, 2, statement, db)
        try bind(title, 3, statement, db)
        try bind(sourceBookmark, 4, statement, db)
        try bind(duration, 5, statement, db)
        try bind(run.modelID, 6, statement, db)
        try bind(run.engine, 7, statement, db)
        try bind(run.language, 8, statement, db)
        try bind(run.appVersion, 9, statement, db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
        return sqlite3_last_insert_rowid(db)
    }

    func appendSegment(_ segment: TranscriptSegment, to id: Int64) throws {
        let db = try connection()
        let statement = try prepare("""
            INSERT INTO transcript_segments (transcript_id, start_s, end_s, text, raw_text)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        try check(sqlite3_bind_double(statement, 2, segment.start), on: db)
        try check(sqlite3_bind_double(statement, 3, segment.end), on: db)
        try bind(segment.text, 4, statement, db)
        try bind(segment.rawText, 5, statement, db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    }

    func setStatus(_ status: TranscriptStatus, reason: String?, for id: Int64) throws {
        let db = try connection()
        let statement = try prepare(
            "UPDATE transcripts SET status = ?1, status_reason = ?2 WHERE id = ?3", on: db)
        defer { sqlite3_finalize(statement) }
        try bind(status.rawValue, 1, statement, db)
        try bind(status == .incomplete ? reason : nil, 2, statement, db)
        try check(sqlite3_bind_int64(statement, 3, id), on: db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
        try requireOneChange(id, on: db)
    }

    func setSummary(_ summary: String?, for id: Int64) throws {
        let db = try connection()
        let statement = try prepare("UPDATE transcripts SET summary = ?1 WHERE id = ?2", on: db)
        defer { sqlite3_finalize(statement) }
        try bind(summary, 1, statement, db)
        try check(sqlite3_bind_int64(statement, 2, id), on: db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
        try requireOneChange(id, on: db)
    }

    func headers() throws -> [TranscriptHeader] {
        let db = try connection()
        let statement = try prepare("""
            SELECT id, created_at, source_kind, title, duration_s, status, status_reason
            FROM transcripts ORDER BY id DESC
            """, on: db)
        defer { sqlite3_finalize(statement) }
        var result: [TranscriptHeader] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try check(step, expected: SQLITE_ROW, on: db)
            result.append(try header(from: statement))
        }
        return result
    }

    func transcript(id: Int64) throws -> Transcript? {
        let db = try connection()
        let statement = try prepare("""
            SELECT id, created_at, source_kind, title, duration_s, status, status_reason,
                   source_bookmark, summary, model_id, engine, language, app_version
            FROM transcripts WHERE id = ?1
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        try check(step, expected: SQLITE_ROW, on: db)

        let header = try header(from: statement)
        let run = TranscriptionRun(modelID: text(statement, 9), engine: text(statement, 10),
                                   language: text(statement, 11),
                                   appVersion: text(statement, 12) ?? TranscriptionRun.unknownAppVersion)
        return Transcript(header: header, run: run, sourceBookmark: data(statement, 7),
                          summary: text(statement, 8), segments: try segments(of: id, on: db))
    }

    func delete(id: Int64) throws {
        let db = try connection()
        // Segments go with their transcript through ON DELETE CASCADE.
        let statement = try prepare("DELETE FROM transcripts WHERE id = ?1", on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    }

    func markAbandonedJobs(reason: String) throws {
        let db = try connection()
        let statement = try prepare("""
            UPDATE transcripts SET status = 'incomplete', status_reason = ?1
            WHERE status = 'inProgress'
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try bind(reason, 1, statement, db)
        try check(sqlite3_step(statement), expected: SQLITE_DONE, on: db)
    }

    // MARK: - Rows

    private func header(from statement: OpaquePointer) throws -> TranscriptHeader {
        guard let kind = text(statement, 2).flatMap(TranscriptSourceKind.init(rawValue:)),
              let title = text(statement, 3),
              let status = text(statement, 5).flatMap(TranscriptStatus.init(rawValue:))
        else {
            throw MacomprendoError.transcriptStore("a stored transcript is invalid")
        }
        let duration: TimeInterval? = sqlite3_column_type(statement, 4) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 4)
        return TranscriptHeader(
            id: sqlite3_column_int64(statement, 0),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            sourceKind: kind, title: title, duration: duration, status: status,
            statusReason: text(statement, 6))
    }

    private func segments(of id: Int64, on db: OpaquePointer) throws -> [TranscriptSegment] {
        let statement = try prepare("""
            SELECT start_s, end_s, text, raw_text FROM transcript_segments
            WHERE transcript_id = ?1 ORDER BY start_s, id
            """, on: db)
        defer { sqlite3_finalize(statement) }
        try check(sqlite3_bind_int64(statement, 1, id), on: db)
        var result: [TranscriptSegment] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            try check(step, expected: SQLITE_ROW, on: db)
            result.append(TranscriptSegment(start: sqlite3_column_double(statement, 0),
                                            end: sqlite3_column_double(statement, 1),
                                            text: text(statement, 2) ?? "",
                                            rawText: text(statement, 3)))
        }
        return result
    }

    // MARK: - SQLite

    private func connection() throws -> OpaquePointer {
        if let handle { return handle.pointer }
        do {
            try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            throw MacomprendoError.transcriptStore(error.localizedDescription)
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK,
              let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let opened { sqlite3_close_v2(opened) }
            throw MacomprendoError.transcriptStore(message)
        }
        do {
            try execute("PRAGMA foreign_keys = ON", on: opened)
            try execute("""
                CREATE TABLE IF NOT EXISTS transcripts (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    created_at REAL NOT NULL,
                    source_kind TEXT NOT NULL CHECK(source_kind IN ('file', 'call')),
                    title TEXT NOT NULL,
                    source_bookmark BLOB,
                    duration_s REAL,
                    status TEXT NOT NULL
                        CHECK(status IN ('inProgress', 'complete', 'incomplete')),
                    status_reason TEXT,
                    model_id TEXT,
                    engine TEXT,
                    language TEXT,
                    app_version TEXT,
                    summary TEXT
                );
                CREATE TABLE IF NOT EXISTS transcript_segments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    transcript_id INTEGER NOT NULL
                        REFERENCES transcripts(id) ON DELETE CASCADE,
                    start_s REAL NOT NULL,
                    end_s REAL NOT NULL,
                    text TEXT NOT NULL,
                    raw_text TEXT
                );
                CREATE INDEX IF NOT EXISTS transcript_segments_by_start
                    ON transcript_segments (transcript_id, start_s);
                PRAGMA user_version = 1;
                """, on: opened)
        } catch {
            sqlite3_close_v2(opened)
            throw error
        }
        handle = TranscriptDatabaseHandle(opened)
        return opened
    }

    private func requireOneChange(_ id: Int64, on db: OpaquePointer) throws {
        guard sqlite3_changes(db) == 1 else {
            throw MacomprendoError.transcriptStore("no transcript has identifier \(id)")
        }
    }

    private func execute(_ sql: String, on db: OpaquePointer) throws {
        try check(sqlite3_exec(db, sql, nil, nil, nil), on: db)
    }

    private func prepare(_ sql: String, on db: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(db, sql, -1, &statement, nil), on: db)
        guard let statement else { throw MacomprendoError.transcriptStore("no statement") }
        return statement
    }

    private func bind(_ value: String?, _ index: Int32, _ statement: OpaquePointer,
                      _ db: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index), on: db)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try check(sqlite3_bind_text(statement, index, value, -1, transient), on: db)
    }

    private func bind(_ value: Data?, _ index: Int32, _ statement: OpaquePointer,
                      _ db: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index), on: db)
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), transient)
        }
        try check(result, on: db)
    }

    private func bind(_ value: Double?, _ index: Int32, _ statement: OpaquePointer,
                      _ db: OpaquePointer) throws {
        guard let value else {
            try check(sqlite3_bind_null(statement, index), on: db)
            return
        }
        try check(sqlite3_bind_double(statement, index, value), on: db)
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private func data(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
              let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private func check(_ result: Int32, expected: Int32 = SQLITE_OK,
                       on db: OpaquePointer) throws {
        guard result == expected else {
            throw MacomprendoError.transcriptStore(String(cString: sqlite3_errmsg(db)))
        }
    }
}

/// Closes the connection when the store goes away; a class so the actor needs no `deinit`.
private final class TranscriptDatabaseHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close_v2(pointer)
    }
}
