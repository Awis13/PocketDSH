import Foundation
import CSQLite
import Darwin

/// A host owns this database for its lifetime. SQL writes are synchronous and
/// confined to this actor; no transaction crosses an actor suspension point.
public actor EventStore {
    private var executionOwners: [String: String] = [:]
    func acquireExecution(session: String, owner: String) throws {
        guard executionOwners[session] == nil else { throw HarnessError.busy }
        executionOwners[session] = owner
    }
    func releaseExecution(session: String, owner: String) {
        if executionOwners[session] == owner { executionOwners.removeValue(forKey: session) }
    }
    private let connection: Connection
    private final class Connection: @unchecked Sendable {
        let db: OpaquePointer
        let lock: Int32
        init(path: String) throws {
            lock = Darwin.open(path + ".lock", O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lock >= 0 else { throw HarnessError.storage("Cannot open store lock") }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
                Darwin.close(lock); throw HarnessError.storage("Store already owned by another host")
            }
            var pointer: OpaquePointer?
            let result = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                Darwin.close(lock); throw HarnessError.storage("Cannot open database")
            }
            db = pointer
        }
        deinit { sqlite3_close(db); Darwin.close(lock) }
    }

    public init(path: String) throws {
        connection = try Connection(path: path)
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE IF NOT EXISTS events (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_session ON events(session,seq);
        CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, workspace TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS commands (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, id TEXT NOT NULL,
          prompt TEXT NOT NULL, mode TEXT NOT NULL, state TEXT NOT NULL,
          UNIQUE(session,id));
        CREATE INDEX IF NOT EXISTS commands_pending ON commands(session,state,seq);
        """
        guard sqlite3_exec(connection.db, schema, nil, nil, nil) == SQLITE_OK else {
            throw HarnessError.storage(String(cString: sqlite3_errmsg(connection.db)))
        }
    }

    public func bindWorkspace(_ workspace: String, session: String) throws {
        guard !session.isEmpty, session.utf8.count <= 128, !session.contains("\0"), !workspace.contains("\0") else {
            throw HarnessError.invalid("Invalid session identity or workspace")
        }
        var stmt: OpaquePointer?
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(connection.db, "INSERT OR IGNORE INTO sessions(id,workspace) VALUES (?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        do {
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_bind_text(stmt, 1, session, -1, transient) == SQLITE_OK,
                  sqlite3_bind_text(stmt, 2, workspace, -1, transient) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
        stmt = nil
        guard sqlite3_prepare_v2(connection.db, "SELECT workspace FROM sessions WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_bind_text(stmt, 1, session, -1, transient) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { throw failure() }
        guard String(cString: value) == workspace else { throw HarnessError.invalid("Session belongs to a different workspace; use a new session ID") }
    }

    public func append(_ events: [SessionEvent], session: String) throws {
        try transaction { try insertEvents(events, session: session) }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        guard sqlite3_exec(connection.db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw failure() }
        do {
            let result = try body()
            guard sqlite3_exec(connection.db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw failure() }
            return result
        } catch {
            sqlite3_exec(connection.db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func insertEvents(_ events: [SessionEvent], session: String) throws {
        for event in events {
                let data = try JSONEncoder().encode(event)
                let body = String(decoding: data, as: UTF8.self)
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(connection.db, "INSERT INTO events(session,body) VALUES (?,?)", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
                defer { sqlite3_finalize(stmt) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                guard sqlite3_bind_text(stmt, 1, session, -1, transient) == SQLITE_OK,
                      sqlite3_bind_text(stmt, 2, body, -1, transient) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }

    /// Admission and the receipt are committed together. Reusing an ID with a
    /// different payload/mode is an error, including after consumption/removal.
    public func enqueue(session: String, id: String, prompt: String, mode: DeliveryMode) throws -> CommandReceipt {
        guard !id.isEmpty, id.utf8.count <= 128, !id.contains("\0"),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 262144, !prompt.contains("\0") else {
            throw HarnessError.invalid("Invalid command ID or prompt (limit 256 KiB)")
        }
        return try transaction {
            if let row = try rows("SELECT prompt,mode,state FROM commands WHERE session=? AND id=?", [session,id]).first {
                guard row[0] == prompt, row[1] == mode.rawValue, let state = CommandState(rawValue: row[2]) else {
                    throw HarnessError.invalid("Command ID reused with a different payload or delivery mode")
                }
                return CommandReceipt(id: id, state: state, duplicate: true)
            }
            guard try pending(session: session).count < 256 else { throw HarnessError.invalid("Pending queue limit reached (256)") }
            _ = try rows("INSERT INTO commands(session,id,prompt,mode,state) VALUES (?,?,?,?,'pending')", [session,id,prompt,mode.rawValue])
            var event = SessionEvent("inbox.accepted"); event.commandID = id
            try insertEvents([event], session: session)
            return CommandReceipt(id: id, state: .pending, duplicate: false)
        }
    }

    public func pending(session: String) throws -> [PendingCommand] {
        try rows("SELECT id,prompt,mode FROM commands WHERE session=? AND state='pending' ORDER BY seq", [session]).map {
            guard let mode = DeliveryMode(rawValue: $0[2]) else { throw HarnessError.storage("Unknown inbox delivery mode") }
            return PendingCommand(id: $0[0], prompt: $0[1], mode: mode)
        }
    }

    public func removePending(session: String, id: String) throws -> Bool {
        try transaction {
            let result = try rows("SELECT state FROM commands WHERE session=? AND id=?", [session,id])
            guard result.first?.first == "pending" else { return false }
            _ = try rows("UPDATE commands SET state='cancelled' WHERE session=? AND id=?", [session,id])
            var event = SessionEvent("inbox.cancelled"); event.commandID = id
            try insertEvents([event], session: session)
            return true
        }
    }

    /// Claim and transcript admission are one transaction; a crash cannot
    /// remove a prompt from the inbox without leaving it in history.
    func claim(session: String, owner: String, startsTurn: Bool, trace: TraceContext) throws -> [Message] {
        guard executionOwners[session] == owner else { throw HarnessError.busy }
        return try transaction {
            let available = try pending(session: session)
            let steering = available.filter { $0.mode == .steer }
            let firstQueued = startsTurn ? available.first { $0.mode == .queue } : nil
            let selected = firstQueued.map { [$0] } ?? []
            let claimed = selected + steering
            guard !claimed.isEmpty else { return [] }
            var events: [SessionEvent] = startsTurn ? [SessionEvent("turn.started")] : []
            let messages = claimed.map { Message(role: "user", content: $0.prompt) }
            for (command, message) in zip(claimed, messages) {
                _ = try rows("UPDATE commands SET state='consumed' WHERE session=? AND id=? AND state='pending'", [session,command.id])
                var event = SessionEvent("message", message: message); event.commandID = command.id
                events.append(event)
            }
            events = events.map { var event = $0; event.trace = trace; return event }
            try insertEvents(events, session: session)
            return messages
        }
    }

    /// Serializes the last steering check with turn closure. Steering accepted
    /// after this transaction belongs to a subsequent turn, never a lost tail.
    func finishIfUnsteered(session: String, owner: String, trace: TraceContext) throws -> Bool {
        guard executionOwners[session] == owner else { throw HarnessError.busy }
        return try transaction {
            guard try !pending(session: session).contains(where: { $0.mode == .steer }) else { return false }
            var event = SessionEvent("turn.ended", detail: "completed"); event.trace = trace
            try insertEvents([event], session: session)
            return true
        }
    }

    private func rows(_ sql: String, _ arguments: [String]) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in arguments.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) == SQLITE_OK else { throw failure() }
        }
        var result: [[String]] = []
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_DONE: return result
            case SQLITE_ROW:
                var row: [String] = []
                for index in 0..<sqlite3_column_count(stmt) {
                    guard let text = sqlite3_column_text(stmt, index) else { throw failure() }
                    row.append(String(cString: text))
                }
                result.append(row)
            default: throw failure()
            }
        }
    }

    public func load(session: String) throws -> [SessionEvent] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, "SELECT body FROM events WHERE session=? ORDER BY seq", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, session, -1, transient) == SQLITE_OK else { throw failure() }
        var events: [SessionEvent] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return events }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_text(stmt, 0) else { throw failure() }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            events.append(try JSONDecoder().decode(SessionEvent.self, from: Data(bytes: bytes, count: count)))
        }
    }

    private func failure() -> HarnessError { .storage(String(cString: sqlite3_errmsg(connection.db))) }
}
