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
        try Self.migrate(connection.db)
    }

    /// Version 0 is the original, unversioned journal. Migration never rewrites
    /// source rows, and the schema marker advances only with the committed state.
    private static func migrate(_ db: OpaquePointer) throws {
        let version = try rows(db, "PRAGMA user_version", []).first?.first
        guard version == "0" || version == "1" else {
            throw HarnessError.storage("Unsupported event-store schema version: \(version ?? "unknown")")
        }
        guard sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;", nil, nil, nil) == SQLITE_OK else {
            throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
        }
        guard version == "0" else { return }
        let schema = """
        BEGIN IMMEDIATE;
        CREATE TABLE IF NOT EXISTS events (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, body TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_session ON events(session,seq);
        CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, workspace TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS commands (
          seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, id TEXT NOT NULL,
          prompt TEXT NOT NULL, mode TEXT NOT NULL, state TEXT NOT NULL,
          UNIQUE(session,id));
        CREATE INDEX IF NOT EXISTS commands_pending ON commands(session,state,seq);
        CREATE TABLE context_state (
          session TEXT PRIMARY KEY, version INTEGER NOT NULL CHECK(version >= 0),
          projection TEXT);
        """
        do {
            guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
                throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT session,body FROM events ORDER BY seq", -1, &statement, nil) == SQLITE_OK else {
                throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
            }
            var counts: [String: Int64] = [:]
            do {
                defer { sqlite3_finalize(statement) }
                while true {
                    let code = sqlite3_step(statement)
                    if code == SQLITE_DONE { break }
                    guard code == SQLITE_ROW, let session = sqlite3_column_text(statement, 0),
                          let body = sqlite3_column_text(statement, 1) else {
                        throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
                    }
                    let data = Data(bytes: body, count: Int(sqlite3_column_bytes(statement, 1)))
                    if try JSONDecoder().decode(SessionEvent.self, from: data).modelMessage != nil {
                        counts[String(cString: session), default: 0] += 1
                    }
                }
            }
            for (session, count) in counts {
                _ = try rows(db, "INSERT INTO context_state(session,version) VALUES (?,?)", [session,String(count)])
            }
            guard sqlite3_exec(db, "PRAGMA user_version=1; COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
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
                if event.modelMessage != nil {
                    _ = try rows("""
                        INSERT INTO context_state(session,version) VALUES (?,1)
                        ON CONFLICT(session) DO UPDATE SET version=version+1
                        """, [session])
                }
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
        try Self.rows(connection.db, sql, arguments)
    }

    private static func rows(_ db: OpaquePointer, _ sql: String, _ arguments: [String]) throws -> [[String]] {
        func failure() -> HarnessError { .storage(String(cString: sqlite3_errmsg(db))) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
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
        try loadSequenced(session: session).map(\.event)
    }

    public func loadSequenced(session: String, after sequence: Int64 = 0) throws -> [SequencedSessionEvent] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(connection.db, "SELECT seq,body FROM events WHERE session=? AND seq>? ORDER BY seq", -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(stmt, 1, session, -1, transient) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, sequence) == SQLITE_OK else { throw failure() }
        var result: [SequencedSessionEvent] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW, let bytes = sqlite3_column_text(stmt, 1) else { throw failure() }
            let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
            result.append(SequencedSessionEvent(sequence: sqlite3_column_int64(stmt, 0),
                event: try JSONDecoder().decode(SessionEvent.self, from: data)))
        }
    }

    public func loadContext(session: String) throws -> ContextSnapshot {
        let state = try rows("SELECT version,COALESCE(projection,'') FROM context_state WHERE session=?", [session]).first
        guard let version = Int64(state?[0] ?? "0"), version >= 0 else { throw failure() }
        var projection: ContextProjection?
        if let json = state?[1], !json.isEmpty {
            // Read the discriminator before the payload, so future formats fail
            // explicitly instead of silently falling back to the full transcript.
            struct Header: Decodable { let formatVersion: Int }
            let data = Data(json.utf8)
            let format = try JSONDecoder().decode(Header.self, from: data).formatVersion
            guard format == 1 else { throw ContextProjectionError.unsupportedFormat(format) }
            projection = try JSONDecoder().decode(ContextProjection.self, from: data)
            guard let metadata = projection?.metadata, metadata.version <= version,
                  metadata.sourceVersion < metadata.version, metadata.coveredFrom > 0,
                  metadata.coveredThrough >= metadata.coveredFrom else { throw failure() }
        }
        return ContextSnapshot(sessionID: session, version: version, projection: projection,
            tail: try loadSequenced(session: session, after: projection?.metadata.coveredThrough ?? 0))
    }

    /// Compare-and-swap the model-only prefix and its audit/provenance together.
    /// An active engine's owner token is required; idle callers may omit it.
    /// No await occurs between checking the version and committing the replacement.
    @discardableResult
    public func replaceContext(session: String, expectedVersion: Int64, through sequence: Int64,
                               summary: String, provenance: ContextSummaryProvenance,
                               owner: String? = nil) throws -> ContextProjection {
        guard executionOwners[session] == owner else { throw HarnessError.busy }
        return try transaction {
            try Task.checkCancellation()
            let current = try loadContext(session: session)
            guard current.version == expectedVersion else { throw ContextProjectionError.staleVersion }
            guard current.version < Int64.max,
                  !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !provenance.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !provenance.requestIDs.isEmpty,
                  provenance.requestIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(provenance.requestIDs).count == provenance.requestIDs.count,
                  provenance.createdAt.timeIntervalSince1970.isFinite else { throw ContextProjectionError.invalidSummary }
            let prefix = current.tail.filter { $0.sequence <= sequence && $0.event.modelMessage != nil }
            guard let first = prefix.first, prefix.last?.sequence == sequence,
                  sequence > (current.projection?.metadata.coveredThrough ?? 0) else {
                throw ContextProjectionError.invalidBoundary
            }
            // Storage rejects cut tool groups too. Selection/recent-turn protection
            // and proving that a summary reduces the prepared request belong to C4.
            var pending: Set<String> = []
            for row in prefix {
                guard let message = row.event.modelMessage else { continue }
                if message.role == "tool" {
                    guard let id = message.toolCallID, pending.remove(id) != nil else {
                        throw ContextProjectionError.invalidBoundary
                    }
                } else {
                    guard pending.isEmpty else { throw ContextProjectionError.invalidBoundary }
                    for call in message.calls {
                        guard message.role == "assistant", !call.id.isEmpty, pending.insert(call.id).inserted else {
                            throw ContextProjectionError.invalidBoundary
                        }
                    }
                }
            }
            guard pending.isEmpty else { throw ContextProjectionError.invalidBoundary }
            let metadata = ContextCompactionMetadata(sourceVersion: current.version, version: current.version + 1,
                coveredFrom: current.projection?.metadata.coveredFrom ?? first.sequence,
                coveredThrough: sequence, provenance: provenance)
            let projection = ContextProjection(formatVersion: 1, summary: summary, metadata: metadata)
            let json = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
            try Task.checkCancellation()
            _ = try rows("UPDATE context_state SET version=?,projection=? WHERE session=? AND version=?",
                [String(metadata.version),json,session,String(expectedVersion)])
            guard sqlite3_changes(connection.db) == 1 else { throw ContextProjectionError.staleVersion }
            var audit = SessionEvent("context.compacted")
            audit.contextCompaction = metadata
            try insertEvents([audit], session: session)
            return projection
        }
    }

    private func failure() -> HarnessError { .storage(String(cString: sqlite3_errmsg(connection.db))) }
}
