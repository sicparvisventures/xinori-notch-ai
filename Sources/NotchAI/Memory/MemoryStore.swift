import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One document in the index — a note, a mail subject, a past exchange, a fact
/// you asked it to remember.
struct MemoryDocument: Sendable {
    let source: MemorySource
    /// Stable identity within its source, so re-indexing updates rather than
    /// duplicates.
    let ref: String
    let title: String
    let body: String
    let modified: Date
}

enum MemorySource: String, CaseIterable, Sendable, Identifiable {
    case notes, mail, conversations, facts

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notes: return "Notities"
        case .mail: return "Mail"
        case .conversations: return "Gesprekken"
        case .facts: return "Onthouden feiten"
        }
    }

    var blurb: String {
        switch self {
        case .notes: return "Apple Notes, titel en tekst"
        case .mail: return "Afzenders en onderwerpen — nooit de inhoud van berichten"
        case .conversations: return "Wat je hier eerder hebt gevraagd en gekregen"
        case .facts: return "Wat je expliciet liet onthouden"
        }
    }

    /// Whether indexing this source needs Full Disk Access.
    var needsFullDiskAccess: Bool {
        self == .notes || self == .mail
    }
}

struct MemoryHit: Sendable, Identifiable {
    let id: Int64
    let source: MemorySource
    let title: String
    let snippet: String
    let modified: Date
    /// Lower is better for FTS (bm25); higher is better for cosine. Only used
    /// for ordering within one search, never shown as an absolute.
    let score: Double
}

/// The index: one SQLite file, FTS5 for words and a vector table for meaning.
///
/// It lives in Application Support and never leaves the machine — an index that
/// spans your notes, mail and conversations is more sensitive than any of them
/// alone, which is why indexing is opt-in per source and there is one button
/// that erases it.
actor MemoryStore {
    static let shared = MemoryStore()

    private var db: OpaquePointer?

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appending(path: "NotchAI")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "memory.sqlite")
    }

    // MARK: - Lifecycle

    private func open() throws {
        guard db == nil else { return }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(Self.fileURL.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            throw MemoryError.cannotOpen(String(cString: sqlite3_errmsg(handle)))
        }
        db = handle

        // `content=''` — a contentless FTS table would save space but makes the
        // snippet impossible to rebuild, and the snippet is what makes a hit
        // readable. Storing the body twice is worth that.
        try exec("""
        PRAGMA journal_mode=WAL;
        -- Off by default in SQLite, which makes ON DELETE CASCADE a comment.
        -- Without it, deleting documents orphans their vectors — and because
        -- rowids get reused, the next document silently inherits a stale
        -- vector belonging to something else entirely.
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS documents(
            id INTEGER PRIMARY KEY,
            source TEXT NOT NULL,
            ref TEXT NOT NULL,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            modified REAL NOT NULL,
            UNIQUE(source, ref)
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
            title, body, content='documents', content_rowid='id', tokenize='unicode61'
        );
        CREATE TABLE IF NOT EXISTS vectors(
            doc_id INTEGER PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
            data BLOB NOT NULL
        );
        CREATE TRIGGER IF NOT EXISTS documents_ai AFTER INSERT ON documents BEGIN
            INSERT INTO documents_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;
        CREATE TRIGGER IF NOT EXISTS documents_ad AFTER DELETE ON documents BEGIN
            INSERT INTO documents_fts(documents_fts, rowid, title, body)
            VALUES('delete', old.id, old.title, old.body);
        END;
        CREATE TRIGGER IF NOT EXISTS documents_au AFTER UPDATE ON documents BEGIN
            INSERT INTO documents_fts(documents_fts, rowid, title, body)
            VALUES('delete', old.id, old.title, old.body);
            INSERT INTO documents_fts(rowid, title, body) VALUES (new.id, new.title, new.body);
        END;
        """)
    }

    private func exec(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "onbekend"
            sqlite3_free(error)
            throw MemoryError.query(message)
        }
    }

    // MARK: - Writing

    @discardableResult
    func upsert(_ document: MemoryDocument) throws -> Int64 {
        try open()
        let sql = """
        INSERT INTO documents(source, ref, title, body, modified)
        VALUES(?, ?, ?, ?, ?)
        ON CONFLICT(source, ref) DO UPDATE SET
            title=excluded.title, body=excluded.body, modified=excluded.modified
        RETURNING id;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, document.source.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, document.ref, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, document.title, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, document.body, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 5, document.modified.timeIntervalSince1970)

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MemoryError.query(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    func storeVector(_ vector: [Float], for id: Int64) throws {
        try open()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO vectors(doc_id, data) VALUES(?, ?);",
                                 -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        vector.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(statement, 2, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
        sqlite3_step(statement)
    }

    /// Documents that have no vector yet, so embedding can resume where it
    /// stopped instead of starting over.
    func documentsWithoutVectors(limit: Int) throws -> [(id: Int64, text: String)] {
        try open()
        let sql = """
        SELECT d.id, d.title || ' ' || substr(d.body, 1, 1500)
        FROM documents d LEFT JOIN vectors v ON v.doc_id = d.id
        WHERE v.doc_id IS NULL LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))

        var rows: [(Int64, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(statement, 0),
                         String(cString: sqlite3_column_text(statement, 1))))
        }
        return rows
    }

    // MARK: - Reading

    /// Word search. FTS5's `bm25` ranks; the raw score is negative, so it is
    /// negated to keep "higher is better" consistent with the vector path.
    func search(_ query: String, sources: Set<MemorySource>, limit: Int) throws -> [MemoryHit] {
        try open()
        let cleaned = Self.ftsQuery(query)
        guard !cleaned.isEmpty else { return [] }

        let filter = sources.isEmpty ? "" :
            "AND d.source IN (\(sources.map { "'\($0.rawValue)'" }.joined(separator: ",")))"
        let sql = """
        SELECT d.id, d.source, d.title,
               snippet(documents_fts, 1, '', '', '…', 18),
               d.modified, bm25(documents_fts)
        FROM documents_fts JOIN documents d ON d.id = documents_fts.rowid
        WHERE documents_fts MATCH ? \(filter)
        ORDER BY bm25(documents_fts) LIMIT ?;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw MemoryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, cleaned, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 2, Int32(limit))

        return collect(statement, scoreIndex: 5, negate: true)
    }

    /// Meaning search: brute-force cosine over every stored vector.
    ///
    /// With a few thousand documents at 768 floats that is a handful of
    /// megabytes and a few milliseconds — an approximate index would be
    /// premature at this scale and another thing to keep correct.
    func semanticSearch(_ query: [Float], sources: Set<MemorySource>, limit: Int) throws -> [MemoryHit] {
        try open()
        let filter = sources.isEmpty ? "" :
            "WHERE d.source IN (\(sources.map { "'\($0.rawValue)'" }.joined(separator: ",")))"
        let sql = """
        SELECT d.id, d.source, d.title, substr(d.body, 1, 200), d.modified, v.data
        FROM vectors v JOIN documents d ON d.id = v.doc_id \(filter);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        let queryNorm = sqrt(query.reduce(0) { $0 + $1 * $1 })
        guard queryNorm > 0 else { return [] }

        var scored: [MemoryHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 5) else { continue }
            let bytes = Int(sqlite3_column_bytes(statement, 5))
            let count = bytes / MemoryLayout<Float>.size
            guard count == query.count else { continue }

            let vector = UnsafeRawBufferPointer(start: blob, count: bytes)
                .bindMemory(to: Float.self)
            var dot: Float = 0, norm: Float = 0
            for index in 0..<count {
                dot += query[index] * vector[index]
                norm += vector[index] * vector[index]
            }
            guard norm > 0 else { continue }

            scored.append(MemoryHit(
                id: sqlite3_column_int64(statement, 0),
                source: MemorySource(rawValue: String(cString: sqlite3_column_text(statement, 1))) ?? .facts,
                title: String(cString: sqlite3_column_text(statement, 2)),
                snippet: String(cString: sqlite3_column_text(statement, 3)),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                score: Double(dot / (queryNorm * sqrt(norm)))))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func collect(_ statement: OpaquePointer?, scoreIndex: Int32, negate: Bool) -> [MemoryHit] {
        var hits: [MemoryHit] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let raw = sqlite3_column_double(statement, scoreIndex)
            hits.append(MemoryHit(
                id: sqlite3_column_int64(statement, 0),
                source: MemorySource(rawValue: String(cString: sqlite3_column_text(statement, 1))) ?? .facts,
                title: String(cString: sqlite3_column_text(statement, 2)),
                snippet: String(cString: sqlite3_column_text(statement, 3)),
                modified: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                score: negate ? -raw : raw))
        }
        return hits
    }

    // MARK: - Housekeeping

    func counts() -> [MemorySource: Int] {
        guard (try? open()) != nil else { return [:] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT source, COUNT(*) FROM documents GROUP BY source;",
                                 -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var result: [MemorySource: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if let source = MemorySource(rawValue: String(cString: sqlite3_column_text(statement, 0))) {
                result[source] = Int(sqlite3_column_int(statement, 1))
            }
        }
        return result
    }

    func embeddedCount() -> Int {
        guard (try? open()) != nil else { return 0 }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM vectors;", -1, &statement, nil) == SQLITE_OK
        else { return 0 }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement, 0)) : 0
    }

    func wipe(_ source: MemorySource?) throws {
        try open()
        if let source {
            // Vectors explicitly as well as by cascade: belt and braces on a
            // constraint that is only enforced when the pragma is on.
            try exec("""
            DELETE FROM vectors WHERE doc_id IN
                (SELECT id FROM documents WHERE source = '\(source.rawValue)');
            DELETE FROM documents WHERE source = '\(source.rawValue)';
            """)
        } else {
            try exec("DELETE FROM vectors; DELETE FROM documents;")
        }
    }

    /// FTS5 treats punctuation as syntax, so a raw user phrase can be a syntax
    /// error rather than a search. Reduce to prefix-matched terms.
    private static func ftsQuery(_ input: String) -> String {
        input
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 }
            .map { "\($0)*" }
            .joined(separator: " OR ")
    }
}

enum MemoryError: LocalizedError {
    case cannotOpen(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case let .cannotOpen(message): return "Kon het geheugen niet openen: \(message)"
        case let .query(message): return "Geheugenfout: \(message)"
        }
    }
}
