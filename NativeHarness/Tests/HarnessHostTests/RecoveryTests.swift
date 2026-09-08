import XCTest
import HarnessCore
@testable import harness

final class RecoveryTests: XCTestCase {
    func testInterruptedWorkClosesWithoutInventingSuccessAndRecoveryIsIdempotent() {
        let history = [NativeEvent(op: "blockStart", id: "shell", text: "upgrade", workspace: "/tmp"),
                       NativeEvent(op: "user", id: "prompt", text: "check"),
                       NativeEvent(op: "toolCall", id: "tool", text: "shell")]
        let repaired = NativeRecovery.events(history, session: "s", engineInterrupted: true, pendingCount: 1)
        XCTAssertEqual(repaired.map(\.op), ["blockEnd", "toolResult", "stage"])
        XCTAssertNil(repaired[0].exitCode)
        XCTAssertEqual(repaired[0].failed, true)
        XCTAssertEqual(repaired[1].failed, true)
        XCTAssertEqual(repaired.last?.stage, "interrupted")
        XCTAssertTrue(NativeRecovery.events(history + repaired, session: "s", engineInterrupted: false, pendingCount: 0).isEmpty)
    }
    func testCompletedWorkIsNotMarkedInterrupted() {
        let history = [NativeEvent(op: "blockStart", id: "shell"), NativeEvent(op: "blockEnd", exitCode: 0),
                       NativeEvent(op: "user", id: "prompt"), NativeEvent(op: "stage", stage: "completed")]
        XCTAssertTrue(NativeRecovery.events(history, session: "s", engineInterrupted: false, pendingCount: 0).isEmpty)
    }
    func testJournalReopensWithByteExactOutputAndFrozenRequestIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("ui.sqlite").path
        let bytes = Data([0, 27, 91, 51, 49, 109, 255, 10])
        let info = NativeSessionInfo(id: "s", title: "New task", workspace: "/tmp", model: "fixture", running: false, updatedAt: 1)
        do {
            let journal = try PresentationJournal(path: path)
            let sink = try NativeSink(journal: journal, info: info)
            sink.send(NativeEvent(op: "blockStart", session: "s", id: "b", text: "printf"))
            sink.send(NativeEvent(op: "pty", session: "s", bytes: bytes))
            XCTAssertEqual(try journal.prepareRequest(session: "s", id: "r", original: "inspect", terminal: true, expanded: "old tail"), "old tail")
        }
        let journal = try PresentationJournal(path: path)
        let restored = try NativeSink(journal: journal, info: info)
        XCTAssertEqual(try journal.sessions(), ["s"])
        XCTAssertEqual(restored.info().title, "printf")
        XCTAssertEqual(try restored.history().last?.bytes, bytes)
        XCTAssertEqual(try journal.prepareRequest(session: "s", id: "r", original: "inspect", terminal: true, expanded: "new tail"), "old tail")
        XCTAssertThrowsError(try journal.prepareRequest(session: "s", id: "r", original: "different", terminal: true, expanded: "new tail"))
        restored.send(NativeEvent(op: "blockEnd", session: "s", exitCode: 7))
        XCTAssertEqual(try restored.history().map(\.sequence), [1, 2, 3])
    }

    func testRequestMetadataAndUnknownFieldsSurviveJournalReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("metadata.sqlite").path
        let metadata = NativeSessionInfo(id: "s", title: "New task", workspace: "/tmp", model: "fixture", running: false, updatedAt: 0)
        let original = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"stage","session":"s","stage":"requesting","futureEnvelope":{"enabled":true},"request":{"requestID":"r","turnID":"t","stage":"requesting","futureRequest":{"data":[1,null,"x"]}}}"#.utf8))
        do {
            let sink = try NativeSink(journal: PresentationJournal(path: path), info: metadata)
            sink.send(original)
            for _ in 0..<270 { sink.send(NativeEvent(op: "stage", session: "s", stage: "queued")) }
        }
        let sink = try NativeSink(journal: PresentationJournal(path: path), info: metadata)
        let history = try sink.history()
        XCTAssertEqual(history.first?.extraFields, original.extraFields)
        XCTAssertEqual(history.first?.request, original.request)
        let recovery = NativeRecovery.events(history, session: "s", engineInterrupted: true, pendingCount: 0)
        XCTAssertEqual(recovery.last?.request?.id, "r")
        XCTAssertEqual(recovery.last?.request?.stage, "interrupted")
        XCTAssertEqual(recovery.last?.request?.string("code"), "HOST_RESTARTED")
        XCTAssertEqual(recovery.last?.request?.fields["futureRequest"], original.request?.fields["futureRequest"])
        recovery.forEach { sink.send($0) }
        XCTAssertTrue(NativeRecovery.events(try sink.history(), session: "s", engineInterrupted: false, pendingCount: 0).isEmpty)
    }
    func testContextProjectionRecoveryLeavesPresentationAndRawTerminalHistoryIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try EventStore(path: root.appendingPathComponent("engine.sqlite").path)
        try await store.append([.init("message", message: .init(role: "user", content: "old prompt")),
            .init("message", message: .init(role: "assistant", content: "old answer"))], session: "s")
        try await store.replaceContext(session: "s", expectedVersion: 2, through: 2,
            summary: "model-only facts", provenance: .init(model: "fixture", requestIDs: ["summary"]))
        let call = ToolCall(id: "call", name: "shell", arguments: "{}")
        try await store.append([.init("turn.started"),
            .init("message", message: .init(role: "assistant", content: "", calls: [call])),
            .init("tool.started", call: call)], session: "s")
        let journal = try PresentationJournal(path: root.appendingPathComponent("ui.sqlite").path)
        let sink = try NativeSink(journal: journal, info: .init(id: "s", title: "fixture", workspace: root.path,
            model: "fixture", running: false, updatedAt: 0))
        let raw = Data([27, 91, 51, 49, 109, 255, 0, 10])
        sink.send(NativeEvent(op: "user", session: "s", id: "old", text: "old prompt"))
        sink.send(NativeEvent(op: "text", session: "s", text: "old answer"))
        sink.send(NativeEvent(op: "blockStart", session: "s", id: "b", text: "htop"))
        sink.send(NativeEvent(op: "pty", session: "s", bytes: raw))
        sink.send(NativeEvent(op: "toolCall", session: "s", id: "call", text: "shell"))
        let before = try sink.history()
        let repairs = SessionEngine.recovery(try await store.load(session: "s"))
        try await store.append(repairs, session: "s")
        NativeRecovery.events(before, session: "s", engineInterrupted: !repairs.isEmpty, pendingCount: 0).forEach { sink.send($0) }
        let context = try await store.loadContext(session: "s")
        XCTAssertTrue(context.messages[0].content.contains("model-only facts"))
        XCTAssertTrue(context.messages.last!.content.contains("TOOL_OUTCOME_UNKNOWN"))
        let history = try sink.history()
        XCTAssertEqual(history.prefix(before.count).map(\.sequence), before.map(\.sequence))
        XCTAssertEqual(history.prefix(before.count).map(\.text), before.map(\.text))
        XCTAssertEqual(history.first { $0.op == "pty" }?.bytes, raw)
        XCTAssertFalse(history.contains { $0.text?.contains("model-only facts") == true })
        XCTAssertTrue(NativeRecovery.events(history, session: "s", engineInterrupted: false, pendingCount: 0).isEmpty)
        let source = try await store.load(session: "s")
        XCTAssertTrue(SessionEngine.recovery(source).isEmpty)
    }

}
