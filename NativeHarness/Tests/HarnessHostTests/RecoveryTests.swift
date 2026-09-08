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
}
