import XCTest
@testable import HarnessCore

private actor ScriptedProvider: ModelProvider {
    var replies: [ModelReply]
    var requests: [[Message]] = []
    init(_ replies: [ModelReply]) { self.replies = replies }
    func complete(messages: [Message], tools: [ToolDefinition], onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        requests.append(messages)
        guard !replies.isEmpty else { throw HarnessError.provider("Script exhausted") }
        return replies.removeFirst()
    }
}

private actor WaitingProvider: ModelProvider {
    private var entered = false
    func hasEntered() -> Bool { entered }
    func complete(messages: [Message], tools: [ToolDefinition], onUpdate: @escaping @Sendable (LiveUpdate) -> Void) async throws -> ModelReply {
        entered = true
        try await Task.sleep(for: .seconds(30))
        return ModelReply(message: .init(role: "assistant", content: "unexpected"))
    }
}

@MainActor final class EngineTests: XCTestCase {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEditLoopPersistsActualResultAndNextRequestSeesIt() async throws {
        let root = try directory()
        try Data("hello old\n".utf8).write(to: root.appendingPathComponent("note.txt"))
        let call = ToolCall(id: "c1", name: "edit_file", arguments: #"{"path":"note.txt","old_text":"old","new_text":"new"}"#)
        let provider = ScriptedProvider([
            ModelReply(message: .init(role: "assistant", content: "", calls: [call]), finishReason: "tool_calls"),
            ModelReply(message: .init(role: "assistant", content: "done"))])
        let store = try EventStore(path: root.appendingPathComponent("history.sqlite").path)
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root, allowWrite: true))
        let final = try await engine.run(prompt: "edit note")
        XCTAssertEqual(final, "done")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8), "hello new\n")
        let requests = await provider.requests
        XCTAssertEqual(requests.last?.last?.toolCallID, "c1")
        let events = try await store.load(session: "a")
        XCTAssertEqual(events.last?.detail, "completed")
        XCTAssertTrue(SessionEngine.recovery(events).isEmpty)
    }

    func testRecoveryDistinguishesStartedFromUnstartedAndDoesNotInventSuccess() {
        let one = ToolCall(id: "a", name: "edit_file", arguments: "{}")
        let two = ToolCall(id: "b", name: "read_file", arguments: "{}")
        let repaired = SessionEngine.recovery([
            .init("turn.started"), .init("message", message: .init(role: "assistant", content: "", calls: [one, two])),
            .init("tool.started", call: one)])
        XCTAssertTrue(repaired[0].message!.content.contains("TOOL_OUTCOME_UNKNOWN"))
        XCTAssertTrue(repaired[1].message!.content.contains("TOOL_NOT_STARTED"))
        XCTAssertEqual(repaired[2].detail, "interrupted")
    }

    func testResumeClosesCrashTailBeforeNewPrompt() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("history.sqlite").path)
        let call = ToolCall(id: "crashed", name: "edit_file", arguments: "{}")
        try await store.append([.init("turn.started"), .init("message", message: .init(role: "assistant", content: "", calls: [call])), .init("tool.started", call: call)], session: "a")
        let provider = ScriptedProvider([ModelReply(message: .init(role: "assistant", content: "resumed"))])
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        _ = try await engine.run(prompt: "inspect before retry")
        let request = await provider.requests[0]
        XCTAssertEqual(request.map(\.role), ["assistant", "tool", "user"])
        XCTAssertTrue(request[1].content.contains("UNKNOWN"))
    }

    func testSecondOwnerCannotOpenDatabase() throws {
        let root = try directory()
        let path = root.appendingPathComponent("history.sqlite").path
        let store = try EventStore(path: path)
        try withExtendedLifetime(store) { XCTAssertThrowsError(try EventStore(path: path)) }
    }

    func testSessionCannotSilentlySwitchWorkspace() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("history.sqlite").path)
        try await store.bindWorkspace("/one", session: "a")
        try await store.bindWorkspace("/one", session: "a")
        do { try await store.bindWorkspace("/two", session: "a"); XCTFail("Must reject changed workspace") } catch { }
    }

    func testScopeDenialAndEditConflictLeaveFileUnchanged() async throws {
        let root = try directory()
        let file = root.appendingPathComponent("note")
        try Data("old old".utf8).write(to: file)
        let readOnly = try WorkspaceTools(root: root)
        let writable = try WorkspaceTools(root: root, allowWrite: true)
        for (tool, call) in [
            (readOnly, ToolCall(id: "1", name: "edit_file", arguments: #"{"path":"note","old_text":"old old","new_text":"new"}"#)),
            (writable, ToolCall(id: "2", name: "edit_file", arguments: #"{"path":"note","old_text":"old","new_text":"new"}"#)),
            (readOnly, ToolCall(id: "3", name: "read_file", arguments: #"{"path":"../outside"}"#))] {
            do { _ = try await tool.execute(call); XCTFail("Must reject") } catch { }
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old old")
    }

    func testBusyAndCancellationEndTurn() async throws {
        let root = try directory()
        let store = try EventStore(path: root.appendingPathComponent("history.sqlite").path)
        let provider = WaitingProvider()
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root))
        let task = Task { try await engine.run(prompt: "wait") }
        for _ in 0..<100 {
            if await provider.hasEntered() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        do { _ = try await engine.run(prompt: "overlap"); XCTFail("Must reject overlapping run") }
        catch HarnessError.busy { }
        task.cancel()
        do { _ = try await task.value; XCTFail("Must cancel") } catch is CancellationError { }
        let events = try await store.load(session: "a")
        XCTAssertEqual(events.last?.detail, "cancelled")
    }

    func testIncompleteModelOutputCannotExecuteTools() async throws {
        let root = try directory()
        try Data("old".utf8).write(to: root.appendingPathComponent("note"))
        let call = ToolCall(id: "c", name: "edit_file", arguments: #"{"path":"note","old_text":"old","new_text":"new"}"#)
        let provider = ScriptedProvider([ModelReply(message: .init(role: "assistant", content: "", calls: [call]), finishReason: "length")])
        let store = try EventStore(path: root.appendingPathComponent("history.sqlite").path)
        let engine = SessionEngine(id: "a", store: store, provider: provider, tools: try WorkspaceTools(root: root, allowWrite: true))
        do { _ = try await engine.run(prompt: "edit"); XCTFail("Must fail") } catch { }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note"), encoding: .utf8), "old")
    }
}
