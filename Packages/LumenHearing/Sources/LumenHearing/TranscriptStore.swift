import Foundation
import SQLite3

/// Local transcript database: SQLite + FTS5 (accent-insensitive `unicode61
/// remove_diacritics 2` tokenizer), `secure_delete` so purged text is
/// overwritten on disk. The file lives only on this Mac (0600, excluded from
/// backups). Raw SQLite3 on purpose: the LorisLabs SQLite/FTS owner
/// (LorisKnowledge) is local-only and not importable yet.
public actor TranscriptStore {
    public enum ProcessingStatus: String, Sendable {
        case transcribed, noSpeech, skipped, failed
    }

    public struct NewTranscript: Sendable {
        public var event: SpeechEvent
        public var transcript: EngineTranscript
        public var created: Date

        public init(event: SpeechEvent, transcript: EngineTranscript, created: Date = Date()) {
            self.event = event
            self.transcript = transcript
            self.created = created
        }
    }

    /// Owns the connection; closed when the store goes away. Only touched on the actor.
    private final class Connection: @unchecked Sendable {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { sqlite3_close(pointer) }
    }
    private let connection: Connection
    private var db: OpaquePointer? { connection.pointer }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `url == nil` opens a private in-memory database (tests).
    public init(url: URL?) throws {
        var handle: OpaquePointer?
        let path: String
        if let url {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            path = url.path
        } else {
            path = ":memory:"
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw HearingError.storage(message)
        }
        connection = Connection(handle)
        try Self.exec(handle, Self.schema)
        if let url {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutable = url
            try? mutable.setResourceValues(values)
        }
    }

    private static let schema = """
    PRAGMA journal_mode = WAL;
    PRAGMA secure_delete = ON;
    CREATE TABLE IF NOT EXISTS transcripts(
        id INTEGER PRIMARY KEY,
        event_id TEXT NOT NULL UNIQUE,
        camera TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL,
        language TEXT,
        text TEXT NOT NULL,
        engine TEXT NOT NULL,
        created REAL NOT NULL,
        audio_seconds REAL,
        processing_seconds REAL,
        segments TEXT NOT NULL DEFAULT '[]'
    );
    CREATE INDEX IF NOT EXISTS transcripts_start ON transcripts(start_time);
    CREATE INDEX IF NOT EXISTS transcripts_camera ON transcripts(camera, start_time);
    CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
        text, content='transcripts', content_rowid='id', tokenize='unicode61 remove_diacritics 2'
    );
    CREATE TRIGGER IF NOT EXISTS transcripts_ai AFTER INSERT ON transcripts BEGIN
        INSERT INTO transcripts_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS transcripts_ad AFTER DELETE ON transcripts BEGIN
        INSERT INTO transcripts_fts(transcripts_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TABLE IF NOT EXISTS processed(
        event_id TEXT PRIMARY KEY,
        status TEXT NOT NULL,
        at REAL NOT NULL
    );
    PRAGMA user_version = 1;
    """

    // MARK: Writes

    @discardableResult
    public func insert(_ item: NewTranscript) throws -> Int64 {
        let segments = String(data: (try? JSONEncoder().encode(item.transcript.segments)) ?? Data("[]".utf8),
                              encoding: .utf8) ?? "[]"
        try run("""
            INSERT INTO transcripts(event_id, camera, start_time, end_time, language, text, engine, created,
                                    audio_seconds, processing_seconds, segments)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """, [
                .text(item.event.id), .text(item.event.camera), .real(item.event.start.timeIntervalSince1970),
                item.event.end.map { .real($0.timeIntervalSince1970) } ?? .null,
                item.transcript.language.map { .text($0) } ?? .null,
                .text(item.transcript.text), .text(item.transcript.engine.rawValue),
                .real(item.created.timeIntervalSince1970), .real(item.transcript.audioSeconds),
                .real(item.transcript.processingSeconds), .text(segments),
            ])
        let id = sqlite3_last_insert_rowid(db)
        try markProcessed(eventID: item.event.id, status: .transcribed, at: item.created)
        return id
    }

    public func markProcessed(eventID: String, status: ProcessingStatus, at date: Date = Date()) throws {
        try run("INSERT INTO processed(event_id, status, at) VALUES (?,?,?) ON CONFLICT(event_id) DO UPDATE SET status = excluded.status, at = excluded.at",
                [.text(eventID), .text(status.rawValue), .real(date.timeIntervalSince1970)])
    }

    public func hasProcessed(eventID: String) throws -> Bool {
        try query("SELECT 1 FROM processed WHERE event_id = ? LIMIT 1", [.text(eventID)]) { _ in true }.first ?? false
    }

    /// Deletes transcripts of events that started before `cutoff`, plus old
    /// processing marks. Returns the number of transcripts removed.
    @discardableResult
    public func purge(olderThan cutoff: Date) throws -> Int {
        let t = cutoff.timeIntervalSince1970
        try run("DELETE FROM transcripts WHERE start_time < ?", [.real(t)])
        let removed = Int(sqlite3_changes(db))
        try run("DELETE FROM processed WHERE at < ?", [.real(t)])
        return removed
    }

    public func deleteAll() throws {
        try Self.exec(db, "DELETE FROM transcripts; DELETE FROM processed; INSERT INTO transcripts_fts(transcripts_fts) VALUES ('rebuild'); VACUUM;")
    }

    // MARK: Reads

    public func count() throws -> Int {
        try query("SELECT COUNT(*) FROM transcripts", []) { Int(sqlite3_column_int64($0, 0)) }.first ?? 0
    }

    public func recent(limit: Int = 100, camera: String? = nil) throws -> [TranscriptRecord] {
        var sql = "SELECT \(Self.columns), NULL FROM transcripts t"
        var args: [Value] = []
        if let camera { sql += " WHERE t.camera = ?"; args.append(.text(camera)) }
        sql += " ORDER BY t.start_time DESC LIMIT ?"
        args.append(.int(Int64(max(1, min(limit, 1000)))))
        return try query(sql, args, Self.record)
    }

    /// Full-text search. Every word must match (prefix match on each word);
    /// accents and case are ignored. An empty query returns recent transcripts.
    public func search(_ text: String, camera: String? = nil, limit: Int = 100) throws -> [TranscriptRecord] {
        guard let match = Self.ftsQuery(text) else { return try recent(limit: limit, camera: camera) }
        var sql = """
            SELECT \(Self.columns), snippet(transcripts_fts, 0, '[', ']', '…', 12)
            FROM transcripts_fts JOIN transcripts t ON t.id = transcripts_fts.rowid
            WHERE transcripts_fts MATCH ?
            """
        var args: [Value] = [.text(match)]
        if let camera { sql += " AND t.camera = ?"; args.append(.text(camera)) }
        sql += " ORDER BY bm25(transcripts_fts), t.start_time DESC LIMIT ?"
        args.append(.int(Int64(max(1, min(limit, 1000)))))
        return try query(sql, args, Self.record)
    }

    /// Builds a safe FTS5 expression: user text never reaches the FTS grammar
    /// unquoted (no column filters, NEAR, or syntax errors from quotes).
    static func ftsQuery(_ text: String) -> String? {
        let words = KeywordMatcher.normalize(text).split(separator: " ").prefix(12)
        guard !words.isEmpty else { return nil }
        return words.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    private static let columns = "t.id, t.event_id, t.camera, t.start_time, t.end_time, t.language, t.text, t.engine, t.created, t.segments"

    private static func record(_ s: OpaquePointer) -> TranscriptRecord {
        func text(_ i: Int32) -> String? { sqlite3_column_text(s, i).map { String(cString: $0) } }
        func real(_ i: Int32) -> Double? { sqlite3_column_type(s, i) == SQLITE_NULL ? nil : sqlite3_column_double(s, i) }
        let segments = text(9).flatMap { try? JSONDecoder().decode([TranscriptSegment].self, from: Data($0.utf8)) } ?? []
        return TranscriptRecord(
            id: sqlite3_column_int64(s, 0), eventID: text(1) ?? "", camera: text(2) ?? "",
            start: Date(timeIntervalSince1970: real(3) ?? 0), end: real(4).map(Date.init(timeIntervalSince1970:)),
            language: text(5), text: text(6) ?? "", engine: text(7) ?? "",
            created: Date(timeIntervalSince1970: real(8) ?? 0), segments: segments, snippet: text(10))
    }

    // MARK: SQLite plumbing

    private enum Value { case text(String), real(Double), int(Int64), null }

    private static func exec(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(error)
            throw HearingError.storage(message)
        }
    }

    private func prepare(_ sql: String, _ args: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw HearingError.storage(String(cString: sqlite3_errmsg(db)))
        }
        for (offset, value) in args.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .real(let d): sqlite3_bind_double(statement, index, d)
            case .int(let i): sqlite3_bind_int64(statement, index, i)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func run(_ sql: String, _ args: [Value]) throws {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        let rc = sqlite3_step(statement)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw HearingError.storage(String(cString: sqlite3_errmsg(db))) }
    }

    private func query<T>(_ sql: String, _ args: [Value], _ row: (OpaquePointer) -> T) throws -> [T] {
        let statement = try prepare(sql, args)
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_ROW { out.append(row(statement)); continue }
            guard rc == SQLITE_DONE else { throw HearingError.storage(String(cString: sqlite3_errmsg(db))) }
            return out
        }
    }
}
