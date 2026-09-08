import Foundation
import CSQLite
import Darwin

/// The host's ordered presentation log, including raw terminal bytes. NORMAL
/// WAL commits survive process crashes without an fsync for every model token.
/// The engine's separate FULL-synchronous journal remains the execution authority.
public final class PresentationJournal: @unchecked Sendable {
    private let db: OpaquePointer
    private let lock = NSLock()
    public init(path: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let pointer else { if let pointer { sqlite3_close(pointer) }; throw HarnessError.storage("Cannot open presentation journal") }
        db = pointer
        chmod(path, S_IRUSR | S_IWUSR)
        do {
            try execute("""
            PRAGMA journal_mode=WAL;
            PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS panels(id TEXT PRIMARY KEY, metadata TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS output(session TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(session,seq));
            CREATE TABLE IF NOT EXISTS requests(session TEXT NOT NULL, id TEXT NOT NULL, original TEXT NOT NULL, terminal TEXT NOT NULL, expanded TEXT NOT NULL, PRIMARY KEY(session,id));
            """)
        } catch { sqlite3_close(db); throw error }
    }
    deinit { sqlite3_close(db) }
    public func sessions() throws -> [String] { try lock.withLock { try rows("SELECT id FROM panels ORDER BY rowid").map { $0[0] } } }
    public func metadata(session: String) throws -> Data? {
        try lock.withLock { try rows("SELECT metadata FROM panels WHERE id=?", [session]).first.map { Data($0[0].utf8) } }
    }
    public func register(session: String, metadata: Data) throws {
        try lock.withLock { _ = try rows("INSERT OR IGNORE INTO panels(id,metadata) VALUES (?,?)", [session, String(decoding: metadata, as: UTF8.self)]) }
    }
    public func load(session: String) throws -> [Data] {
        try lock.withLock { try rows("SELECT body FROM output WHERE session=? ORDER BY seq", [session]).map { Data($0[0].utf8) } }
    }
    public func append(session: String, sequence: Int, event: Data, metadata: Data) throws {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                _ = try rows("INSERT INTO output(session,seq,body) VALUES (?,?,?)", [session, String(sequence), String(decoding: event, as: UTF8.self)])
                _ = try rows("UPDATE panels SET metadata=? WHERE id=?", [String(decoding: metadata, as: UTF8.self), session])
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
        }
    }
    /// Freeze terminal context on first admission. Retries of the same user
    /// request must not silently acquire a different terminal tail.
    public func prepareRequest(session: String, id: String, original: String, terminal: Bool, expanded: String) throws -> String {
        try lock.withLock {
            let mode = terminal ? "1" : "0"
            if let existing = try rows("SELECT original,terminal,expanded FROM requests WHERE session=? AND id=?", [session,id]).first {
                guard existing[0] == original, existing[1] == mode else { throw HarnessError.invalid("Request ID reused with different input") }
                return existing[2]
            }
            _ = try rows("INSERT INTO requests(session,id,original,terminal,expanded) VALUES (?,?,?,?,?)", [session,id,original,mode,expanded])
            return expanded
        }
    }
    public func originalRequest(session: String, id: String) throws -> String? {
        try lock.withLock { try rows("SELECT original FROM requests WHERE session=? AND id=?", [session,id]).first?.first }
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func rows(_ sql: String, _ values: [String] = []) throws -> [[String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            guard sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        var result: [[String]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String] = []
            for index in 0..<sqlite3_column_count(statement) {
                guard let value = sqlite3_column_text(statement, index) else { throw failure() }
                row.append(String(cString: value))
            }
            result.append(row)
        }
    }
    private func failure() -> HarnessError { .storage(String(cString: sqlite3_errmsg(db))) }
}
