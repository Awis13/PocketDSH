import XCTest
@testable import HarnessCore

private struct DiagnosticProvider: TestModelProvider {
    let fail: Bool
    func complete(_ request: PreparedModelRequest, onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        onUpdate(.providerHeaders)
        onUpdate(.reasoning("PRIVATE_REASONING"))
        if fail { throw HarnessError.provider("PRIVATE_ERROR_WITH_KEY") }
        onUpdate(.text("PRIVATE_ANSWER"))
        return ModelReply(message: .init(role: "assistant", content: "PRIVATE_ANSWER"))
    }
}

private actor DiagnosticWaitingProvider: TestModelProvider {
    var entered = false
    func complete(_ request: PreparedModelRequest, onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        entered = true
        try await Task.sleep(for: .seconds(30))
        throw HarnessError.provider("Should have cancelled")
    }
}

@MainActor final class DiagnosticIntegrationTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testSensitiveContentsExcludedAndJournalIDsMatch() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("journal").path)
        let engine = SessionEngine(id: "PRIVATE_SESSION", store: store, provider: DiagnosticProvider(fail: false), tools: try WorkspaceTools(root: root))
        _ = try await engine.run(prompt: "PRIVATE_PROMPT")
        let snapshot = await engine.diagnostics()!
        let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(json.contains("PRIVATE_"))
        XCTAssertEqual(snapshot.events.first?.stage, .accepted)
        XCTAssertEqual(snapshot.events.last?.stage, .completed)
        XCTAssertEqual(snapshot.requests.count, 1)
        XCTAssertNotNil(snapshot.requests[0].firstReasoningMS)
        XCTAssertNotNil(snapshot.requests[0].firstTextMS)
        XCTAssertNil(snapshot.requests[0].firstDataMS) // fake provider never emitted this signal
        let journal = try await store.load(session: "PRIVATE_SESSION")
        XCTAssertEqual(journal.last?.trace?.turnID, snapshot.events.last?.context.turnID)
        XCTAssertEqual(journal.last?.trace?.requestID, snapshot.events.last?.context.requestID)
        XCTAssertEqual(journal.last?.trace?.sessionID, snapshot.events.first?.context.sessionID)
    }
    func testErrorClassificationDoesNotLeakRawError() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("journal").path)
        let engine = SessionEngine(id: "private", store: store, provider: DiagnosticProvider(fail: true), tools: try WorkspaceTools(root: root))
        do { _ = try await engine.run(prompt: "PRIVATE_PROMPT"); XCTFail("Must fail") } catch { }
        let snapshot = await engine.diagnostics()!
        XCTAssertEqual(snapshot.events.last?.stage, .failed)
        XCTAssertEqual(snapshot.events.last?.code, "PROVIDER_FAILURE")
        XCTAssertEqual(snapshot.requests.last?.stage, "failed")
        XCTAssertEqual(snapshot.requests.last?.code, "PROVIDER_FAILURE")
        XCTAssertEqual(snapshot.requests.last?.purpose, "conversation")
        XCTAssertNil(snapshot.requests.last?.firstTextMS)
        XCTAssertNotNil(snapshot.requests.last?.budget)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self).contains("PRIVATE_"))
    }
    func testPublicCancelWhileProviderIsWaiting() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("journal").path)
        let provider = DiagnosticWaitingProvider()
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        let task = Task { try await engine.run(prompt: "wait") }
        for _ in 0..<100 {
            if await provider.entered { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let active = await engine.diagnostics()!
        XCTAssertEqual(active.events.last?.stage, .requesting)
        let duplicate = SessionEngine(id: "a", store: store, provider: DiagnosticProvider(fail: false), tools: try WorkspaceTools(root: root))
        do { _ = try await duplicate.run(prompt: "overlap through a second actor"); XCTFail("Must preserve a single session owner") }
        catch HarnessError.busy { }
        await engine.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError { }
        let final = await engine.diagnostics()!
        XCTAssertEqual(final.events.last?.stage, .cancelled)
        XCTAssertTrue(final.events.contains { $0.stage == .cancellationRequested })
        let events = try await store.load(session: "a")
        XCTAssertEqual(events.last?.detail, "cancelled")
    }
    func testArchiveRoundtripBoundsAndRefusesOverwrite() throws {
        let root = try directory()
        let url = root.appendingPathComponent("trace.json")
        let archive = try DiagnosticArchive(url: url)
        let trace = DiagnosticTrace()
        for _ in 0..<270 {
            trace.record(.ready)
            try archive.append(trace.snapshot().events.last!)
        }
        let loaded = try DiagnosticArchive.read(url: url)
        XCTAssertEqual(loaded.events.count, 256)
        XCTAssertEqual(loaded.droppedEvents, 14)
        XCTAssertEqual(loaded.events.last?.sequence, 270)
        XCTAssertThrowsError(try DiagnosticArchive(url: url))
        XCTAssertEqual(try DiagnosticArchive.read(url: url).events.last?.sequence, 270)
    }

    func testArchiveRetainsFinalRequestAfterStartEvicted() throws {
        let root = try directory(), trace = DiagnosticTrace()
        let url = root.appendingPathComponent("request.json")
        let archive = try DiagnosticArchive(url: url)
        trace.beginRequest(); trace.record(.requesting)
        for event in trace.snapshot().events { try archive.append(event) }
        for _ in 0..<260 { trace.record(.queued); try archive.append(trace.snapshot().events.last!) }
        trace.record(.failed, code: "HTTP_400"); try archive.append(trace.snapshot().events.last!)
        let report = try DiagnosticArchive.read(url: url)
        XCTAssertFalse(report.events.contains { $0.stage == .requesting })
        XCTAssertEqual(report.requests?.last?.stage, "failed")
        XCTAssertEqual(report.requests?.last?.code, "HTTP_400")
        XCTAssertEqual(report.requests?.last?.turnID, trace.identifiers().turnID)
        XCTAssertNotNil(report.requests?.last?.elapsedMS)
        XCTAssertNil(report.requests?.last?.firstTextMS)
    }
}
