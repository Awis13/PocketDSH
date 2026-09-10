import XCTest
import CSQLite
@testable import HarnessCore

final class CompactionConcurrencyTests: CompactionTestCase {
    func testCancellationDuringSummaryAndAfterResponseRejectsLateResult() async throws {
        for afterResponse in [false, true] {
            let provider = CompactionProvider()
            await provider.configure(holdSummary: !afterResponse, holdValidation: afterResponse)
            let (engine, store, _) = try await fixture(provider)
            let original = try await store.loadContext(session: "s")
            let work = Task { try await engine.compact(operationID: "cancel") }
            try await wait(provider)
            await engine.cancel()
            await provider.release() // Deliberately ignore cancellation inside the provider.
            let result = try await work.value
            XCTAssertEqual(result.state, .cancelled)
            XCTAssertEqual(result.code, "CANCELLED")
            let retained = try await store.loadContext(session: "s")
            XCTAssertEqual(retained.messages, original.messages)
            XCTAssertEqual(retained.version, original.version)
            let count = await provider.generated.count
            let retry = try await engine.compact(operationID: "cancel")
            XCTAssertEqual(retry, result)
            let newCount = await provider.generated.count
            XCTAssertEqual(count, newCount)
        }
    }

    func testCancellationAfterCommitReturnsCommittedSuccess() async throws {
        let provider = CompactionProvider()
        let (engine, store, _) = try await fixture(provider)
        let result = try await engine.compact(operationID: "commit-wins") { update in
            if case .diagnostic(let event) = update, event.stage == .completed {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        XCTAssertEqual(result.state, .completed)
        let snapshot = try await store.loadContext(session: "s")
        XCTAssertEqual(snapshot.version, result.version)
        XCTAssertNotNil(snapshot.projection)
        let stored = try await engine.compactionReceipt(operationID: "commit-wins")
        XCTAssertEqual(stored, result)
    }

    func testNewModelMessageAndChangedProviderInvalidatePreparedSummary() async throws {
        for modelChange in [false, true] {
            let provider = CompactionProvider()
            await provider.configure(holdSummary: true)
            let (engine, store, _) = try await fixture(provider)
            let work = Task { try await engine.compact(operationID: "stale") }
            try await wait(provider)
            if modelChange { try await provider.changeModel() }
            else { try await store.append([.init("message", message: .init(role: "user", content: "new source message"))], session: "s") }
            await provider.release()
            let result = try await work.value
            XCTAssertEqual(result.state, .failed)
            XCTAssertEqual(result.code, modelChange ? CompactionError.parametersChanged.rawValue : "CONTEXT_STALE")
            let context = try await store.loadContext(session: "s")
            XCTAssertNil(context.projection)
            if !modelChange { XCTAssertEqual(context.messages.last?.content, "new source message") }
        }
    }

    func testQueueAndSteerDuringMaintenanceAreDrainedExactlyOnceWithoutOverlap() async throws {
        let provider = CompactionProvider()
        await provider.configure(holdSummary: true)
        let (engine, store, _) = try await fixture(provider)
        let driver = SessionDriver(engine: engine)
        let work = Task { try await driver.compact(operationID: "manual") }
        try await wait(provider)
        let repeated = try await driver.compact(operationID: "manual")
        XCTAssertEqual(repeated.state, .running)
        do { _ = try await driver.compact(operationID: "other"); XCTFail("Must be busy") } catch HarnessError.busy { }
        do { _ = try await engine.run(prompt: "overlap"); XCTFail("Must be busy") } catch HarnessError.busy { }
        _ = try await driver.submit(prompt: "queued during summary", commandID: "q")
        _ = try await driver.submit(prompt: "steered during summary", mode: .steer, commandID: "s")
        let status = try await driver.status()
        XCTAssertTrue(status.compacting)
        XCTAssertEqual(status.pendingCount, 2)
        await provider.release()
        let result = try await work.value
        XCTAssertEqual(result.state, .completed)
        await driver.waitUntilIdle()
        let pending = try await engine.pending()
        XCTAssertTrue(pending.isEmpty)
        let generated = await provider.generated
        let normal = generated.filter { $0.messages.first?.content.hasPrefix("Summarize historical") != true }
        XCTAssertEqual(normal.count, 1)
        XCTAssertEqual(normal[0].messages.suffix(2).map(\.content), ["queued during summary", "steered during summary"])
        let events = try await store.load(session: "s")
        XCTAssertEqual(events.filter { $0.message?.content == "queued during summary" }.count, 1)
        XCTAssertEqual(events.filter { $0.message?.content == "steered during summary" }.count, 1)
    }

    func testBusyConversationRefusesManualAndStopLeavesPendingQueue() async throws {
        let provider = CompactionProvider()
        await provider.configure(holdSummary: true)
        let (engine, _, _) = try await fixture(provider)
        let driver = SessionDriver(engine: engine)
        _ = try await driver.submit(prompt: "automatic summary first", commandID: "run")
        try await wait(provider)
        let active = try await driver.status()
        XCTAssertTrue(active.compacting)
        do { _ = try await driver.compact(operationID: "manual"); XCTFail("Must not compete with automatic compaction") }
        catch HarnessError.busy { }
        _ = try await driver.submit(prompt: "keep queued", commandID: "later")
        await driver.stop()
        await provider.release()
        await driver.waitUntilIdle()
        let pending = try await engine.pending()
        XCTAssertEqual(pending.map(\.id), ["later"])
        let status = try await driver.status()
        XCTAssertTrue(status.paused)
        let generated = await provider.generated
        XCTAssertTrue(generated.allSatisfy { $0.messages.first?.content.hasPrefix("Summarize historical") == true })
    }

    func testTwoEnginesShareExecutionOwner() async throws {
        let provider = CompactionProvider()
        await provider.configure(holdSummary: true)
        let (engine, store, tools) = try await fixture(provider)
        let other = SessionEngine(id: "s", store: store, provider: provider, tools: tools)
        let work = Task { try await engine.compact(operationID: "owner") }
        try await wait(provider)
        do { _ = try await other.compact(operationID: "other"); XCTFail("Second actor must not acquire the same session") }
        catch HarnessError.busy { }
        await provider.release()
        let result = try await work.value
        XCTAssertEqual(result.state, .completed)
    }

    func testReceiptWriteFailureRollsBackProjectionAndItsAudit() async throws {
        let root = try directory(), path = root.appendingPathComponent("db").path
        let store = try EventStore(path: path)
        try await seed(store)
        try sql(path, "CREATE TRIGGER refuse_completed BEFORE UPDATE ON context_operations WHEN instr(NEW.receipt,'completed')>0 BEGIN SELECT RAISE(ABORT,'injected'); END")
        let engine = SessionEngine(id: "s", store: store, provider: CompactionProvider(), tools: CompactionTools(root.path))
        let result = try await engine.compact(operationID: "atomic")
        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.code, "STORAGE_FAILURE")
        let context = try await store.loadContext(session: "s")
        XCTAssertNil(context.projection)
        XCTAssertEqual(context.version, 12)
        let events = try await store.load(session: "s")
        XCTAssertFalse(events.contains { $0.kind == "context.compacted" })
        let receipt = try await store.compactionReceipt(session: "s", operationID: "atomic")
        XCTAssertEqual(receipt, result)
    }

    func testRestartBeforeAndAfterCommitRetainsReceiptWithoutRepeatingInference() async throws {
        let root = try directory(), path = root.appendingPathComponent("db").path
        let provider = CompactionProvider()
        var completed: CompactionReceipt!
        do {
            let store = try EventStore(path: path)
            try await seed(store)
            let engine = SessionEngine(id: "s", store: store, provider: provider, tools: CompactionTools(root.path))
            completed = try await engine.compact(operationID: "completed")
            let snapshot = try await store.loadContext(session: "s")
            let prepared = try await provider.prepare(messages: snapshot.messages, tools: [], requestID: "crashed")
            let budget = try await provider.measure(prepared, anchor: nil)
            try await store.acquireExecution(session: "s", owner: "crashed")
            _ = try await store.beginCompaction(session: "s", owner: "crashed", operationID: "unfinished",
                sourceVersion: snapshot.version, fingerprint: prepared.fingerprint, before: budget)
        }
        let count = await provider.generated.count
        for _ in 0..<2 {
            let reopened = try EventStore(path: path)
            let engine = SessionEngine(id: "s", store: reopened, provider: provider, tools: CompactionTools(root.path))
            let successful = try await engine.compact(operationID: "completed")
            let interrupted = try await engine.compact(operationID: "unfinished")
            XCTAssertEqual(successful, completed)
            XCTAssertEqual(interrupted.state, .interrupted)
            XCTAssertEqual(interrupted.code, CompactionError.interrupted.rawValue)
            let context = try await reopened.loadContext(session: "s")
            XCTAssertEqual(context.version, completed.version)
        }
        let after = await provider.generated.count
        XCTAssertEqual(count, after)
    }

    func testVersionOneMigrationPreservesInstalledProjection() async throws {
        let root = try directory(), path = root.appendingPathComponent("db").path
        var expected: ContextProjection!
        do {
            let store = try EventStore(path: path)
            try await seed(store)
            expected = try await store.replaceContext(session: "s", expectedVersion: 12, through: 3,
                summary: "legacy summary", provenance: .init(model: "fixture", requestIDs: ["old"]))
        }
        try sql(path, "DROP TABLE context_operations; PRAGMA user_version=1;")
        let store = try EventStore(path: path)
        let context = try await store.loadContext(session: "s")
        XCTAssertEqual(context.projection, expected)
        XCTAssertEqual(context.version, 13)
        let receipt = try await store.compactionReceipt(session: "s", operationID: "none")
        XCTAssertNil(receipt)
    }

    private func sql(_ path: String, _ command: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw HarnessError.storage("fixture open") }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, command, nil, nil, nil) == SQLITE_OK else { throw HarnessError.storage(String(cString: sqlite3_errmsg(db))) }
    }
}
