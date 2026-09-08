import XCTest
import Foundation
import Darwin
@testable import HarnessCore

final class ShellTests: XCTestCase, @unchecked Sendable {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.resolvingSymlinksInPath()
    }
    // Adapted from Home Rig's test: removed unused scripts and nonexistent WORKSPACE.
    func testOutputExitAndWorkspace() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        try Data("marker".utf8).write(to: root.appendingPathComponent("marker.txt"))
        let block = try await ShellRunner.run(command: "pwd; cat marker.txt; printf problem >&2; exit 7", workspace: root.path)
        let physical = try XCTUnwrap(root.path.withCString { realpath($0, nil) })
        defer { free(physical) }
        XCTAssertEqual(block.stdout, String(cString: physical) + "\nmarker")
        XCTAssertEqual(block.stderr, "problem")
        XCTAssertEqual(block.exitCode, 7)
        XCTAssertEqual(block.outcome, "exited")
    }
    func testTimeoutAndOutputLimit() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let slow = try await ShellRunner.run(command: "sleep 10", workspace: root.path, timeout: 0.1)
        XCTAssertEqual(slow.outcome, "timedOut")
        let noisy = try await ShellRunner.run(command: "while true; do printf 1234567890; done", workspace: root.path, outputLimit: 101)
        XCTAssertEqual(noisy.outcome, "outputLimit")
        XCTAssertEqual(noisy.stdout.utf8.count + noisy.stderr.utf8.count, 101)
    }
    func testCancellationKillsGroupAndStreamsBeforeExit() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let stream = AsyncStream<ShellOutput>.makeStream()
        let worker = Task {
            try await ShellRunner.run(command: "sleep 15 & echo $!; wait", workspace: root.path, onOutput: { stream.continuation.yield($0) })
        }
        var iterator = stream.stream.makeAsyncIterator()
        let first = await iterator.next()
        let pid = Int32(String(decoding: try XCTUnwrap(first).bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        worker.cancel()
        let result = try await worker.value
        XCTAssertEqual(result.outcome, "cancelled")
        // A reparented child can briefly remain a zombie; it cannot keep running.
        let child = try XCTUnwrap(pid)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var lastState = ""
        repeat {
            let check = try await ShellRunner.run(command: "ps -o stat= -p \(child)", workspace: root.path)
            lastState = check.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if lastState.isEmpty || lastState.hasPrefix("Z") { return }
            // kill() requests termination; descendants are reaped by their own
            // parent or launchd, so allow bounded kernel scheduling latency.
            try await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        XCTFail("Child remained active after group cancellation: \(lastState)")
    }
    func testEscapingBackgroundPipeDoesNotHangAndStdinIsEOF() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let block = try await ShellRunner.run(command: "sleep 10 & cat; echo complete", workspace: root.path, timeout: 1)
        XCTAssertEqual(block.outcome, "exited")
        XCTAssertEqual(block.stdout, "complete\n")
        XCTAssertLessThan(try XCTUnwrap(block.endedAt).timeIntervalSince(block.startedAt), 2)
    }
    func testApprovalOneUseCancellationAndClose() async throws {
        let controller = ApprovalController()
        let call = ToolCall(id: "tool", name: "shell", arguments: "{}")
        let request = ApprovalRequest(id: "permission", call: call, workspace: "/tmp")
        let stream = AsyncStream<ApprovalRequest>.makeStream()
        let waiter = Task { try await controller.request(request, notify: { stream.continuation.yield($0) }) }
        var iterator = stream.stream.makeAsyncIterator(); _ = await iterator.next()
        let accepted = await controller.answer(id: request.id, allow: true)
        XCTAssertTrue(accepted); let allowed = try await waiter.value; XCTAssertTrue(allowed)
        let repeated = await controller.answer(id: request.id, allow: true); XCTAssertFalse(repeated)
        let cancelled = Task { try await controller.request(request, notify: { stream.continuation.yield($0) }) }
        _ = await iterator.next(); cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let stale = await controller.answer(id: request.id, allow: true); XCTAssertFalse(stale)
        await controller.close()
        let closed = try await controller.request(request, notify: { _ in XCTFail("Closed controller advertised a request") })
        XCTAssertFalse(closed)
    }
    func testDeniedShellHasNoEffectAndApprovedEditRechecksFile() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let controller = ApprovalController()
        let tools = try WorkspaceTools(root: root, approvals: controller)
        let stream = AsyncStream<ApprovalRequest>.makeStream()
        let context = ToolExecutionContext(update: { if case .approval(let request) = $0 { stream.continuation.yield(request) } })
        var iterator = stream.stream.makeAsyncIterator()
        let shell = Task { try await tools.execute(.init(id: "s", name: "shell", arguments: "{\"command\":\"touch forbidden\"}"), context: context) }
        let nextRequest = await iterator.next()
        let request = try XCTUnwrap(nextRequest)
        _ = await controller.answer(id: request.id, allow: false)
        do { _ = try await shell.value; XCTFail("Denied command executed") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
        let file = root.appendingPathComponent("file"); try Data("old".utf8).write(to: file)
        let edit = Task { try await tools.execute(.init(id: "e", name: "edit_file", arguments: "{\"path\":\"file\",\"old_text\":\"old\",\"new_text\":\"new\"}"), context: context) }
        let nextEdit = await iterator.next()
        let editRequest = try XCTUnwrap(nextEdit)
        try Data("human change".utf8).write(to: file)
        _ = await controller.answer(id: editRequest.id, allow: true)
        do { _ = try await edit.value; XCTFail("Overwrote concurrent edit") } catch {}
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "human change")
    }
    func testTerminalHistoryIsExplicitContextOnly() async throws {
        let root = try workspace(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try EventStore(path: root.appendingPathComponent("history.db").path)
        let terminal = TerminalSession(store: store, session: "human", tools: try WorkspaceTools(root: root))
        let block = try await terminal.run(command: "printf terminal-only")
        let history = try await store.load(session: "human")
        XCTAssertTrue(history.allSatisfy { $0.message == nil })
        let context = try await terminal.context(blockID: block.id)
        XCTAssertTrue(context.contains("terminal-only"))
        XCTAssertTrue(context.contains("untrusted"))
        let restored = TerminalSession(store: store, session: "human", tools: try WorkspaceTools(root: root))
        let blocks = try await restored.blocks(); XCTAssertEqual(blocks.map(\.id), [block.id])
    }
}
