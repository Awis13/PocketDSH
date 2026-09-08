import XCTest
import CSQLite
@testable import HarnessCore

@MainActor final class ContextProjectionTests: XCTestCase {
    private let provenance = ContextSummaryProvenance(model: "fixture", requestIDs: ["summary-1"],
        createdAt: Date(timeIntervalSince1970: 100))

    private func path() throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("events.sqlite").path
    }

    @discardableResult private func sql(_ path: String, _ sql: String, _ arguments: [String] = []) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw HarnessError.storage("fixture open") }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw HarnessError.storage(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, text) in arguments.enumerated() {
            guard sqlite3_bind_text(stmt, Int32(index + 1), text, -1, transient) == SQLITE_OK else {
                throw HarnessError.storage("fixture bind")
            }
        }
        var result: [[String]] = []
        while true {
            let code = sqlite3_step(stmt)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw HarnessError.storage(String(cString: sqlite3_errmsg(db))) }
            result.append((0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_text(stmt, $0)!) })
        }
    }

    func testLegacyMigrationRetainsOriginalBytesAndIsIdempotent() async throws {
        let path = try path()
        try sql(path, "CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, body TEXT NOT NULL)")
        try sql(path, "CREATE TABLE sessions(id TEXT PRIMARY KEY, workspace TEXT NOT NULL)")
        try sql(path, "INSERT INTO sessions VALUES ('s','/legacy-workspace')")
        try sql(path, "CREATE TABLE commands(seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, id TEXT NOT NULL, prompt TEXT NOT NULL, mode TEXT NOT NULL, state TEXT NOT NULL, UNIQUE(session,id))")
        try sql(path, "INSERT INTO commands(session,id,prompt,mode,state) VALUES ('s','queued','keep pending','queue','pending')")
        let original = [
            #"{ "kind":"turn.started", "future":true }"#,
            #"{ "kind":"message", "message":{"role":"user","content":"old 👾","calls":[]} }"#,
            #"{"kind":"message","message":{"role":"assistant","content":"old answer","calls":[]}}"#,
            #"{"kind":"turn.ended"}"#]
        for body in original { try sql(path, "INSERT INTO events(session,body) VALUES ('s',?)", [body]) }
        let before = try sql(path, "SELECT seq,session,body FROM events ORDER BY seq")
        for _ in 0..<2 {
            let store = try EventStore(path: path)
            let context = try await store.loadContext(session: "s")
            let legacy = try await store.load(session: "s")
            XCTAssertEqual(context.messages, legacy.compactMap(\.message))
            XCTAssertEqual(context.messages.map(\.content), ["old 👾", "old answer"])
            XCTAssertNil(context.projection)
            XCTAssertEqual(context.version, 2)
            let pending = try await store.pending(session: "s")
            XCTAssertEqual(pending.map(\.prompt), ["keep pending"])
            try await store.bindWorkspace("/legacy-workspace", session: "s")
            do { try await store.bindWorkspace("/different", session: "s"); XCTFail("Migration must preserve workspace binding") }
            catch HarnessError.invalid { }
        }
        XCTAssertEqual(try sql(path, "PRAGMA user_version"), [["1"]])
        XCTAssertEqual(try sql(path, "SELECT seq,session,body FROM events ORDER BY seq"), before)
    }

    func testFutureDatabaseSchemaRefusesWithoutChangingIt() throws {
        let path = try path()
        try sql(path, "PRAGMA user_version=99")
        XCTAssertThrowsError(try EventStore(path: path)) { error in
            XCTAssertTrue(String(describing: error).contains("schema version: 99"))
        }
        XCTAssertEqual(try sql(path, "PRAGMA user_version"), [["99"]])
        XCTAssertEqual(try sql(path, "SELECT name FROM sqlite_master WHERE type='table'"), [])
    }

    func testMigrationFailureRollsBackSchemaAndPreservesSource() throws {
        let path = try path()
        try sql(path, "CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, body TEXT NOT NULL)")
        try sql(path, "INSERT INTO events(session,body) VALUES ('s','invalid JSON')")
        XCTAssertThrowsError(try EventStore(path: path))
        XCTAssertEqual(try sql(path, "PRAGMA user_version"), [["0"]])
        XCTAssertEqual(try sql(path, "SELECT body FROM events"), [["invalid JSON"]])
        XCTAssertEqual(try sql(path, "SELECT name FROM sqlite_master WHERE name='context_state'"), [])
    }

    func testSequencesAreMonotonicAndSessionScoped() async throws {
        let store = try EventStore(path: path())
        try await store.append([.init("message", message: .init(role: "user", content: "one"))], session: "a")
        try await store.append([.init("message", message: .init(role: "user", content: "foreign"))], session: "b")
        try await store.append([.init("audit"), .init("message", message: .init(role: "assistant", content: "two"))], session: "a")
        let a = try await store.loadSequenced(session: "a")
        let b = try await store.loadSequenced(session: "b")
        XCTAssertEqual(a.map(\.sequence), [1, 3, 4])
        XCTAssertEqual(b.map(\.sequence), [2])
        let tail = try await store.loadSequenced(session: "a", after: 1)
        XCTAssertEqual(tail.map(\.sequence), [3, 4])
        for invalid: Int64 in [0, 2, 3, 999] {
            do {
                try await store.replaceContext(session: "a", expectedVersion: 2, through: invalid,
                    summary: "summary", provenance: provenance)
                XCTFail("Must reject foreign, audit, missing and empty boundary")
            } catch ContextProjectionError.invalidBoundary { }
        }
        let other = try await store.loadContext(session: "b")
        XCTAssertEqual(other.messages.map(\.content), ["foreign"])
    }

    func testReplacementPersistsSummaryTailAndAuditWithoutRewritingEvents() async throws {
        let path = try path()
        var projection: ContextProjection!
        var original: [[String]] = []
        do {
            let store = try EventStore(path: path)
            try await store.append([
                .init("message", message: .init(role: "user", content: "old request")),
                .init("message", message: .init(role: "assistant", content: "old answer")),
                .init("message", message: .init(role: "user", content: "recent"))], session: "s")
            original = try sql(path, "SELECT seq,session,body FROM events ORDER BY seq")
            projection = try await store.replaceContext(session: "s", expectedVersion: 3, through: 2,
                summary: "facts", provenance: provenance)
            XCTAssertEqual(projection.metadata.sourceVersion, 3)
            XCTAssertEqual(projection.metadata.version, 4)
            XCTAssertEqual(projection.metadata.coveredFrom, 1)
            XCTAssertEqual(projection.metadata.coveredThrough, 2)
            XCTAssertEqual(projection.metadata.provenance, provenance)
        }
        let reopened = try EventStore(path: path)
        let context = try await reopened.loadContext(session: "s")
        XCTAssertEqual(context.version, 4)
        XCTAssertEqual(context.projection, projection)
        XCTAssertEqual(context.messages, [projection.message, Message(role: "user", content: "recent")])
        XCTAssertTrue(context.messages[0].calls.isEmpty)
        XCTAssertEqual(context.messages[0].role, "user")
        XCTAssertEqual(try sql(path, "SELECT seq,session,body FROM events WHERE seq<=3 ORDER BY seq"), original)
        let events = try await reopened.load(session: "s")
        XCTAssertEqual(events.compactMap(\.message).map(\.content), ["old request", "old answer", "recent"])
        XCTAssertEqual(events.last?.kind, "context.compacted")
        XCTAssertNil(events.last?.message)
        XCTAssertEqual(events.last?.contextCompaction, projection.metadata)
    }

    func testAuditAndPendingInboxDoNotInvalidateButClaimAndMessageDo() async throws {
        let store = try EventStore(path: path())
        try await store.append([.init("message", message: .init(role: "user", content: "old"))], session: "s")
        let before = try await store.loadContext(session: "s")
        try await store.append([.init("audit"), .init("tool.started"), .init("pty")], session: "s")
        _ = try await store.enqueue(session: "s", id: "q", prompt: "pending", mode: .queue)
        let afterAudit = try await store.loadContext(session: "s")
        XCTAssertEqual(afterAudit.version, before.version)
        try await store.replaceContext(session: "s", expectedVersion: before.version, through: 1,
            summary: "old summary", provenance: provenance)
        let summarized = try await store.loadContext(session: "s")
        try await store.acquireExecution(session: "s", owner: "o")
        _ = try await store.claim(session: "s", owner: "o", startsTurn: true, trace: TraceContext(sessionID: "s", turnID: "turn"))
        await store.releaseExecution(session: "s", owner: "o")
        let claimed = try await store.loadContext(session: "s")
        XCTAssertEqual(claimed.version, summarized.version + 1)
        XCTAssertEqual(claimed.projection, summarized.projection)
        XCTAssertEqual(claimed.messages.last?.content, "pending")
        try await store.append([.init("message", message: .init(role: "assistant", content: "new answer"))], session: "s")
        let changed = try await store.loadContext(session: "s")
        XCTAssertEqual(changed.version, claimed.version + 1)
        do {
            try await store.replaceContext(session: "s", expectedVersion: claimed.version,
                through: changed.tail.last!.sequence, summary: "stale", provenance: provenance)
            XCTFail("A newer message must invalidate the frozen version")
        } catch ContextProjectionError.staleVersion { }
        let retained = try await store.loadContext(session: "s")
        XCTAssertEqual(retained.messages, changed.messages)
        XCTAssertEqual(retained.version, changed.version)
    }

    func testAuditWriteFailureRollsBackReplacementAndProvenance() async throws {
        let path = try path()
        let store = try EventStore(path: path)
        try await store.append([.init("message", message: .init(role: "user", content: "one")),
            .init("message", message: .init(role: "assistant", content: "two"))], session: "s")
        try await store.replaceContext(session: "s", expectedVersion: 2, through: 1,
            summary: "first", provenance: provenance)
        let before = try await store.loadContext(session: "s")
        let original = try sql(path, "SELECT seq,session,body FROM events ORDER BY seq")
        try sql(path, "CREATE TRIGGER refuse_audit BEFORE INSERT ON events WHEN instr(NEW.body,'context.compacted')>0 BEGIN SELECT RAISE(ABORT,'injected'); END")
        do {
            try await store.replaceContext(session: "s", expectedVersion: before.version, through: 2,
                summary: "replacement", provenance: .init(model: "other", requestIDs: ["new"]))
            XCTFail("Audit failure must roll back the projection written before it")
        } catch HarnessError.storage { }
        let after = try await store.loadContext(session: "s")
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.projection, before.projection)
        XCTAssertEqual(after.messages, before.messages)
        XCTAssertEqual(try sql(path, "SELECT seq,session,body FROM events ORDER BY seq"), original)
        try sql(path, "DROP TRIGGER refuse_audit")
        let next = try await store.replaceContext(session: "s", expectedVersion: before.version, through: 2,
            summary: "replacement", provenance: provenance)
        XCTAssertEqual(next.metadata.coveredFrom, 1)
        XCTAssertEqual(next.metadata.coveredThrough, 2)
        XCTAssertEqual(next.metadata.version, before.version + 1)
        do {
            try await store.replaceContext(session: "s", expectedVersion: before.version, through: 2,
                summary: "duplicate", provenance: provenance)
            XCTFail("Replacement itself advances the generation")
        } catch ContextProjectionError.staleVersion { }
    }

    func testFailedMessageAppendDoesNotAdvanceVersion() async throws {
        let path = try path()
        let store = try EventStore(path: path)
        try sql(path, "CREATE TRIGGER refuse_second BEFORE INSERT ON events WHEN instr(NEW.body,'second')>0 BEGIN SELECT RAISE(ABORT,'injected'); END")
        do {
            try await store.append([.init("message", message: .init(role: "user", content: "first")),
                .init("message", message: .init(role: "user", content: "second"))], session: "s")
            XCTFail("Batch failure must undo earlier rows and version increments")
        } catch HarnessError.storage { }
        let context = try await store.loadContext(session: "s")
        XCTAssertEqual(context.version, 0)
        XCTAssertTrue(context.tail.isEmpty)
    }

    func testRejectsPartialToolPairsAndAllowsCompleteMultipleCallGroup() async throws {
        let store = try EventStore(path: path())
        let calls = [ToolCall(id: "a", name: "one", arguments: "{}"), ToolCall(id: "b", name: "two", arguments: "{}")]
        try await store.append([.init("message", message: .init(role: "assistant", content: "", calls: calls)),
            .init("message", message: .init(role: "tool", content: "result", toolCallID: "a")),
            .init("message", message: .init(role: "tool", content: "result", toolCallID: "b"))], session: "s")
        for boundary: Int64 in [1, 2] {
            do {
                try await store.replaceContext(session: "s", expectedVersion: 3, through: boundary,
                    summary: "partial", provenance: provenance)
                XCTFail("Must retain every tool result together with its call")
            } catch ContextProjectionError.invalidBoundary { }
        }
        try await store.replaceContext(session: "s", expectedVersion: 3, through: 3,
            summary: "complete", provenance: provenance)
        let result = try await store.loadContext(session: "s")
        XCTAssertEqual(result.messages.count, 1)
    }

    func testBusyOwnerAndInvalidSummaryCannotReplaceContext() async throws {
        let store = try EventStore(path: path())
        try await store.append([.init("message", message: .init(role: "user", content: "old"))], session: "s")
        try await store.acquireExecution(session: "s", owner: "active")
        for owner: String? in [nil, "other"] {
            do {
                try await store.replaceContext(session: "s", expectedVersion: 1, through: 1,
                    summary: "summary", provenance: provenance, owner: owner)
                XCTFail("Only the active execution owner may replace context")
            } catch HarnessError.busy { }
        }
        do {
            try await store.replaceContext(session: "s", expectedVersion: 1, through: 1,
                summary: " \n", provenance: provenance, owner: "active")
            XCTFail("An empty summary cannot discard history")
        } catch ContextProjectionError.invalidSummary { }
        try await store.replaceContext(session: "s", expectedVersion: 1, through: 1,
            summary: "summary", provenance: provenance, owner: "active")
        await store.releaseExecution(session: "s", owner: "active")
    }

    func testFutureProjectionFormatFailsExplicitly() async throws {
        let path = try path()
        let store = try EventStore(path: path)
        try await store.append([.init("message", message: .init(role: "user", content: "old"))], session: "s")
        try sql(path, "UPDATE context_state SET projection=? WHERE session='s'", [#"{"formatVersion":99,"future":"payload"}"#])
        do { _ = try await store.loadContext(session: "s"); XCTFail("Must not fall back to a different model context") }
        catch ContextProjectionError.unsupportedFormat(99) { }
        let original = try await store.load(session: "s")
        XCTAssertEqual(original.first?.message?.content, "old")
    }
}
