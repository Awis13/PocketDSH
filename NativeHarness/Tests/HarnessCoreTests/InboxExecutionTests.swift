import XCTest
import CSQLite
@testable import HarnessCore

private actor InboxProvider: TestModelProvider {
    var requests: [[Message]] = []
    private var gate: CheckedContinuation<ModelReply, Error>?
    let hold: Bool
    init(hold: Bool = true) { self.hold = hold }
    func complete(_ request: PreparedModelRequest, onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        requests.append(request.messages)
        if requests.count == 1 && hold {
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { gate = $0 }
            } onCancel: { Task { await self.abort() } }
        }
        return ModelReply(message: Message(role: "assistant", content: "answer \(requests.count)"))
    }
    func release() { gate?.resume(returning: ModelReply(message: .init(role: "assistant", content: "first answer"))); gate = nil }
    func abort() { gate?.resume(throwing: CancellationError()); gate = nil }
    func waiting() -> Bool { gate != nil }
}

@MainActor final class InboxExecutionTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func wait(_ provider: InboxProvider) async throws {
        for _ in 0..<200 {
            if await provider.waiting() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw HarnessError.invalid("Gate did not open")
    }
    func testSteeringStaysInTurnAndQueueStartsAnotherTurn() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("db").path)
        let provider = InboxProvider()
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        let task = Task { try await engine.run(prompt: "initial") }
        try await wait(provider)
        _ = try await engine.enqueue(prompt: "later task", commandID: "queue")
        _ = try await engine.enqueue(prompt: "adjust current task", mode: .steer, commandID: "steer")
        await provider.release()
        _ = try await task.value
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].last?.content, "initial")
        XCTAssertEqual(requests[1].last?.content, "adjust current task")
        XCTAssertFalse(requests[1].contains { $0.content == "later task" })
        XCTAssertEqual(requests[2].last?.content, "later task")
        let events = try await store.load(session: "a")
        XCTAssertEqual(events.filter { $0.kind == "turn.started" }.count, 2)
        XCTAssertEqual(events.filter { $0.kind == "turn.ended" }.count, 2)
        XCTAssertEqual(events.filter { $0.commandID == "steer" && $0.message != nil }.count, 1)
        let again = try await engine.enqueue(prompt: "later task", commandID: "queue")
        XCTAssertEqual(again.state, .consumed)
        _ = try await engine.runPending()
        let count = await provider.requests.count
        XCTAssertEqual(count, 3)
    }
    func testCancellationPreservesUnclaimedWorkForExplicitResume() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("db").path)
        let provider = InboxProvider()
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        let task = Task { try await engine.run(prompt: "initial") }
        try await wait(provider)
        _ = try await engine.enqueue(prompt: "queued", commandID: "q")
        _ = try await engine.enqueue(prompt: "steering", mode: .steer, commandID: "s")
        await engine.cancel()
        do { _ = try await task.value; XCTFail("Should cancel") } catch is CancellationError { }
        let pending = try await engine.pending()
        XCTAssertEqual(pending.map(\.id), ["q", "s"])
        let replacement = InboxProvider(hold: false)
        let resumed = SessionEngine(id: "a", store: store, provider: replacement, tools: try WorkspaceTools(root: root))
        _ = try await resumed.runPending()
        let requests = await replacement.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].suffix(2).map(\.content), ["queued", "steering"])
        let remaining = try await resumed.pending()
        XCTAssertTrue(remaining.isEmpty)
    }
    func testDriverWakesAgainAfterIdleAndDoesNotReplayDuplicate() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("db").path)
        let provider = InboxProvider(hold: false)
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        let driver = SessionDriver(engine: engine)
        _ = try await driver.submit(prompt: "one", commandID: "1")
        await driver.waitUntilIdle()
        _ = try await driver.submit(prompt: "two", commandID: "2")
        await driver.waitUntilIdle()
        _ = try await driver.submit(prompt: "two", commandID: "2")
        await driver.waitUntilIdle()
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        let status = try await driver.status()
        XCTAssertFalse(status.running)
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testConcurrentSubmissionsDoNotGetStrandedDuringDrainSettlement() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("db").path)
        let provider = InboxProvider(hold: false)
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        let driver = SessionDriver(engine: engine)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask { _ = try await driver.submit(prompt: "task \(index)", commandID: "\(index)") }
            }
            try await group.waitForAll()
        }
        await driver.waitUntilIdle()
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 30)
        let pending = try await engine.pending()
        XCTAssertTrue(pending.isEmpty)
        let events = try await store.load(session: "a")
        XCTAssertEqual(events.filter { $0.kind == "turn.started" }.count, 30)
        XCTAssertEqual(events.filter { $0.kind == "turn.ended" }.count, 30)
    }
    func testSteeringAfterCommittedCloseBecomesANewTurn() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("db").path)
        try await store.acquireExecution(session: "a", owner: "owner")
        let trace = DiagnosticTrace(sessionID: "a")
        _ = try await store.enqueue(session: "a", id: "first", prompt: "one", mode: .queue)
        _ = try await store.claim(session: "a", owner: "owner", startsTurn: true, trace: trace.identifiers())
        let closed = try await store.finishIfUnsteered(session: "a", owner: "owner", trace: trace.identifiers())
        XCTAssertTrue(closed)
        _ = try await store.enqueue(session: "a", id: "late", prompt: "late steer", mode: .steer)
        let claimed = try await store.claim(session: "a", owner: "owner", startsTurn: true, trace: trace.identifiers())
        XCTAssertEqual(claimed.map(\.content), ["late steer"])
        let events = try await store.load(session: "a")
        XCTAssertEqual(events.filter { $0.kind == "turn.started" }.count, 2)
        await store.releaseExecution(session: "a", owner: "owner")
    }

    func testFailedTranscriptWriteRollsBackClaimAndTurnStart() async throws {
        let root = try directory()
        let path = root.appendingPathComponent("db").path
        let store = try EventStore(path: path)
        _ = try await store.enqueue(session: "a", id: "one", prompt: "keep me", mode: .queue)
        try await store.acquireExecution(session: "a", owner: "owner")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER refuse_message BEFORE INSERT ON events WHEN instr(NEW.body, '\"message\"') > 0 BEGIN SELECT RAISE(ABORT, 'injected'); END", nil, nil, nil), SQLITE_OK)
        let context = DiagnosticTrace().identifiers()
        do {
            _ = try await store.claim(session: "a", owner: "owner", startsTurn: true, trace: context)
            XCTFail("Injected write must fail")
        } catch { }
        let pending = try await store.pending(session: "a")
        let events = try await store.load(session: "a")
        XCTAssertEqual(pending.map(\.id), ["one"])
        XCTAssertFalse(events.contains { $0.kind == "turn.started" })
        XCTAssertEqual(sqlite3_exec(db, "DROP TRIGGER refuse_message", nil, nil, nil), SQLITE_OK)
        let claimed = try await store.claim(session: "a", owner: "owner", startsTurn: true, trace: context)
        XCTAssertEqual(claimed.map(\.content), ["keep me"])
        await store.releaseExecution(session: "a", owner: "owner")
    }
}
