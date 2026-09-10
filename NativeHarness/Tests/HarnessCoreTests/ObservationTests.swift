import XCTest
import Foundation
@testable import HarnessCore

final class ObservationTests: XCTestCase, @unchecked Sendable {
    func testCursorsPaginationAndEvictionAreExplicit() throws {
        let history = try TerminalObservation(id: "one", initialWorkspace: "/tmp", capacity: 8)
        history.append(Data("abcd".utf8))
        let first = try history.read(after: 0, maxBytes: 2)
        XCTAssertEqual(first.text, "ab"); XCTAssertEqual(first.nextCursor, 2)
        history.append(Data("efghij".utf8))
        let second = try history.read(after: first.nextCursor)
        XCTAssertEqual(second.text, "cdefghij"); XCTAssertFalse(second.gap)
        let stale = try history.read(after: 0)
        XCTAssertTrue(stale.gap); XCTAssertEqual(stale.startCursor, 2); XCTAssertEqual(stale.nextCursor, 10)
        XCTAssertThrowsError(try history.read(after: 11))
        XCTAssertThrowsError(try history.read(after: -1))
        XCTAssertEqual(history.inspect().retainedBytes, 8)
    }
    func testExistingBytesReturnImmediatelyAndWaitIsCancellable() async throws {
        let history = try TerminalObservation(id: "one", initialWorkspace: "/tmp")
        history.append(Data("early".utf8))
        let alreadyThere = try await history.wait(after: 0, timeout: 1)
        XCTAssertEqual(alreadyThere.text, "early")
        let waiter = Task { try await history.wait(after: 5, timeout: 60) }
        for _ in 0..<200 {
            if history.inspect().pendingWaits == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(history.inspect().pendingWaits, 1)
        waiter.cancel()
        do { _ = try await waiter.value; XCTFail("Expected cancelled wait") } catch is CancellationError {}
        XCTAssertEqual(history.inspect().pendingWaits, 0)
        history.append(Data("later".utf8))
        XCTAssertEqual(try history.read(after: 5).text, "later")
    }
    func testTimeoutExitAndDuplicateFinish() async throws {
        let history = try TerminalObservation(id: "one", initialWorkspace: "/tmp")
        let timeout = try await history.wait(after: 0, timeout: 0.02)
        XCTAssertTrue(timeout.timedOut); XCTAssertEqual(history.inspect().pendingWaits, 0)
        let waiter = Task { try await history.wait(after: 0, timeout: 1) }
        history.finish(PTYExit(code: 7, signal: nil, closedByHost: false))
        history.finish(PTYExit(code: 99, signal: nil, closedByHost: false))
        history.append(Data("after exit".utf8))
        let ended = try await waiter.value
        XCTAssertEqual(ended.exit?.code, 7); XCTAssertEqual(ended.latestCursor, 0)
        XCTAssertEqual(history.inspect().pendingWaits, 0)
    }
    func testRegistrationRaceDoesNotLoseBytes() async throws {
        let history = try TerminalObservation(id: "one", initialWorkspace: "/tmp")
        for index in 0..<100 {
            let waiter = Task { try await history.wait(after: Int64(index), timeout: 1) }
            history.append(Data([UInt8(index)]))
            let read = try await waiter.value
            XCTAssertEqual(read.bytes, Data([UInt8(index)])); XCTAssertFalse(read.timedOut)
        }
        XCTAssertEqual(history.inspect().pendingWaits, 0)
    }
    func testByteFragmentsReassembleAndCatalogEvictsOnlyClosed() throws {
        let history = try TerminalObservation(id: "one", initialWorkspace: "/tmp")
        let data = Data("Привет 🌍".utf8)
        for byte in data { history.append(Data([byte])) }
        var result = Data(), cursor: Int64 = 0
        while cursor < Int64(data.count) {
            let part = try history.read(after: cursor, maxBytes: 1)
            result.append(part.bytes); cursor = part.nextCursor
        }
        XCTAssertEqual(result, data)
        let catalog = TerminalObservations()
        for index in 0..<8 { _ = try catalog.create(id: "\(index)", workspace: "/tmp") }
        XCTAssertThrowsError(try catalog.create(id: "overflow", workspace: "/tmp"))
        try catalog.find("0").finish(PTYExit(code: 0, signal: nil, closedByHost: false))
        _ = try catalog.create(id: "new", workspace: "/tmp")
        XCTAssertThrowsError(try catalog.find("0")); XCTAssertEqual(catalog.list().count, 8)
    }
    func testRealPTYCanBeObservedAfterItStarts() async throws {
        let history = try TerminalObservation(id: "real", initialWorkspace: "/tmp")
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, observation: history, onOutput: { _ in })
        defer { session.close() }
        try session.write(Data("printf '\\nEARLY\\n'; sleep 0.3; printf '\\nLATE\\n'; exit 0\r".utf8))
        var seen = Data(), cursor: Int64 = 0
        var witnessedEarly = false, witnessedLate = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        repeat {
            let part = try await history.wait(after: cursor, timeout: 1)
            seen.append(part.bytes); cursor = part.nextCursor
            let text = String(decoding: seen, as: UTF8.self)
            if text.contains("\r\nEARLY\r\n") && !text.contains("\r\nLATE\r\n") { witnessedEarly = true }
            if text.contains("\r\nLATE\r\n") { witnessedLate = true }
            if part.exit != nil { break }
        } while ContinuousClock.now < deadline
        XCTAssertTrue(witnessedEarly); XCTAssertTrue(witnessedLate)
        XCTAssertEqual(history.inspect().exit?.code, 0)
        XCTAssertEqual(try history.read(after: cursor).bytes.count, 0)
    }
    func testToolWaitDoesNotHoldPTYInputOrRequireWritePermission() async throws {
        let catalog = TerminalObservations()
        let history = try catalog.create(id: "user-terminal", workspace: "/tmp")
        let tools = try WorkspaceTools(root: FileManager.default.temporaryDirectory, observations: catalog)
        let waiter = Task { try await tools.execute(ToolCall(id: "wait", name: "terminal_wait", arguments: "{\"terminal_id\":\"user-terminal\",\"after\":\"0\",\"timeout_seconds\":\"1\"}")) }
        history.append(Data("update continues".utf8))
        let result = try JSONSerialization.jsonObject(with: Data(try await waiter.value.output.utf8)) as! [String: Any]
        XCTAssertEqual(result["text"] as? String, "update continues")
        XCTAssertNil(result["bytes"])
        XCTAssertFalse(tools.definitions.contains { $0.name == "terminal_send" })
    }

    func testModelExcerptBoundsRedrawsWithoutChangingRawHistoryOrCursors() throws {        let history = try TerminalObservation(id: "tui", initialWorkspace: "/tmp")
        let output = Data((String(repeating: "\u{1b}[2;39H\u{1b}[31mCPU Привет 85%\u{1b}[0m\r\n", count: 1000) + "FINAL_MARKER").utf8)
        history.append(output)
        let raw = try history.read(after: 0, maxBytes: 65536)
        let compact = try TerminalModelContext.encode(raw)
        let result = try JSONSerialization.jsonObject(with: Data(compact.utf8)) as! [String: Any]
        let text = try XCTUnwrap(result["text"] as? String)
        XCTAssertLessThanOrEqual(text.utf8.count, 4096)
        XCTAssertTrue(text.hasSuffix("FINAL_MARKER"))
        XCTAssertFalse(text.contains("\u{1b}")); XCTAssertFalse(text.contains("�"))
        XCTAssertNil(result["bytes"]); XCTAssertEqual(result["previewTruncated"] as? Bool, true)
        XCTAssertEqual(result["nextCursor"] as? Int64, raw.nextCursor)
        XCTAssertEqual(try history.read(after: 0, maxBytes: 65536).bytes, output)
        let legacy = String(decoding: try JSONEncoder().encode(raw), as: UTF8.self)
        XCTAssertEqual(TerminalModelContext.compactLegacy(legacy, toolResult: true), compact)
        let prefix = "Please inspect.\n\nSelected terminal tui. Initial workspace: /tmp.\n"
        XCTAssertEqual(TerminalModelContext.compactLegacy(prefix + legacy, toolResult: false), prefix + compact)
        XCTAssertEqual(TerminalModelContext.compactLegacy(prefix + compact, toolResult: false), prefix + compact)
        XCTAssertEqual(TerminalModelContext.compactLegacy("Keep user text {bytes: secret}", toolResult: false), "Keep user text {bytes: secret}")
    }

    func testCommandLifecyclePairsStartAndReady() throws {
        let history = try TerminalObservation(id: "life", initialWorkspace: "/tmp")
        history.recordStart(command: "cd /; false", directory: "/tmp")
        history.append(Data("some output".utf8))
        XCTAssertEqual(history.commandHistory(limit: 8).count, 1)
        XCTAssertNil(history.commandHistory(limit: 8)[0].endedAt)
        history.recordReady(code: 1, directory: "/")
        let open = history.commandHistory(limit: 8)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open[0].command, "cd /; false")
        XCTAssertEqual(open[0].exitCode, 1)
        XCTAssertEqual(open[0].directory, "/")
        XCTAssertNotNil(open[0].startedAt); XCTAssertNotNil(open[0].endedAt)
        XCTAssertEqual(history.currentDirectory, "/")
    }
    func testStandaloneReadyBeforeAnyCommandIsRecorded() throws {
        let history = try TerminalObservation(id: "life", initialWorkspace: "/tmp")
        history.recordReady(code: 0, directory: "/tmp")
        let records = history.commandHistory(limit: 8)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].command)
        XCTAssertEqual(records[0].exitCode, 0)
        XCTAssertEqual(records[0].directory, "/tmp")
        history.recordStart(command: "ls", directory: "/tmp")
        history.recordReady(code: 0, directory: "/tmp")
        XCTAssertEqual(history.commandHistory(limit: 8).map(\.command), [nil, "ls"])
    }
    func testCommandHistoryEvictsOldestAndClampsFields() throws {
        let history = try TerminalObservation(id: "life", initialWorkspace: "/tmp")
        let long = String(repeating: "x", count: 10_000)
        for index in 0..<100 {
            history.recordStart(command: "cmd \(index)", directory: "/tmp")
            if index == 50 { history.recordStart(command: long, directory: long) }
            history.recordReady(code: 0, directory: "/tmp")
        }
        let records = history.commandHistory(limit: 64)
        XCTAssertEqual(records.count, 64)
        XCTAssertEqual(history.commandCount(), 64)
        XCTAssertEqual(records.first?.command, "cmd 37")
        XCTAssertEqual(records.last?.command, "cmd 99")
        let clamped = records.first { $0.command?.hasPrefix("xxx") == true }!
        XCTAssertEqual(clamped.command?.utf8.count, 4096)
        let directoryHistory = try TerminalObservation(id: "dirs", initialWorkspace: "/tmp")
        directoryHistory.recordReady(code: 0, directory: long)
        XCTAssertEqual(directoryHistory.commandHistory(limit: 1).first?.directory?.utf8.count, 4096)
        XCTAssertEqual(records.filter { $0.endedAt == nil }.count, 1, "Only the open clamps record should remain open")
    }
    func testTerminalCommandsToolIsReadOnlyAndUntrusted() async throws {
        let catalog = TerminalObservations()
        let history = try catalog.create(id: "user-terminal", workspace: "/tmp")
        let tools = try WorkspaceTools(root: FileManager.default.temporaryDirectory, observations: catalog)
        history.recordStart(command: "printf hi", directory: "/tmp")
        history.recordReady(code: 0, directory: "/tmp")
        let output = try await tools.execute(ToolCall(id: "commands", name: "terminal_commands", arguments: "{\"terminal_id\":\"user-terminal\",\"limit\":\"8\"}")).output
        XCTAssertFalse(output.contains("\u{1b}"))
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        XCTAssertNil(result["bytes"])
        XCTAssertEqual(result["terminalID"] as? String, "user-terminal")
        XCTAssertTrue((result["format"] as? String)?.contains("untrusted data") == true)
        let commands = try XCTUnwrap(result["commands"] as? [[String: Any]])
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0]["command"] as? String, "printf hi")
        XCTAssertEqual(commands[0]["exitCode"] as? Int, 0)
        XCTAssertEqual(commands[0]["directory"] as? String, "/tmp")
        XCTAssertTrue(tools.definitions.contains { $0.name == "terminal_commands" })
        XCTAssertFalse(tools.definitions.contains { $0.name == "terminal_send" })
        do {
            _ = try await tools.execute(ToolCall(id: "bad", name: "terminal_commands", arguments: "{\"terminal_id\":\"user-terminal\",\"limit\":\"0\"}"))
            XCTFail("Expected invalid limit to be rejected")
        } catch {}
    }
    func testCommandHistoryStripsControlSequencesFromModelOutput() async throws {
        let catalog = TerminalObservations()
        let history = try catalog.create(id: "escapes", workspace: "/tmp")
        history.recordStart(command: "printf '\u{1b}[31mred\u{1b}[0m'", directory: "\u{1b}]0;evil\u{07}/tmp")
        history.recordReady(code: 0, directory: "/tmp")
        let tools = try WorkspaceTools(root: FileManager.default.temporaryDirectory, observations: catalog)
        let output = try await tools.execute(ToolCall(id: "commands", name: "terminal_commands", arguments: "{\"terminal_id\":\"escapes\"}")).output
        XCTAssertFalse(output.contains("\u{1b}"))
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        let command = ((result["commands"] as? [[String: Any]])?.first)?["command"] as? String
        XCTAssertEqual(command, "printf 'red'")
    }
    func testCommandFinishedConditionIgnoresBytesAndWakesOnReady() async throws {
        let history = try TerminalObservation(id: "cond", initialWorkspace: "/tmp")
        let waiter = Task { try await history.wait(after: 0, timeout: 2, condition: .commandFinished) }
        for _ in 0..<200 {
            if history.inspect().pendingWaits == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        history.append(Data("chatty output".utf8))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(history.inspect().pendingWaits, 1, "Output bytes must not satisfy a lifecycle wait")
        history.recordStart(command: "make test", directory: "/tmp")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(history.inspect().pendingWaits, 1, "A start alone must not satisfy the wait")
        history.recordReady(code: 2, directory: "/tmp")
        let result = try await waiter.value
        XCTAssertEqual(result.condition, "command_finished")
        XCTAssertEqual(result.command?.command, "make test")
        XCTAssertEqual(result.command?.exitCode, 2)
        XCTAssertEqual(result.cwd, "/tmp")
        XCTAssertFalse(result.timedOut)
    }
    func testCwdChangedConditionRequiresANewChange() async throws {
        let history = try TerminalObservation(id: "cwd", initialWorkspace: "/tmp")
        history.recordReady(code: 0, directory: "/tmp")
        let waiter = Task { try await history.wait(after: 0, timeout: 2, condition: .cwdChanged) }
        for _ in 0..<200 {
            if history.inspect().pendingWaits == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        history.recordStart(command: "cd /etc", directory: "/tmp")
        history.recordReady(code: 0, directory: "/tmp")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(history.inspect().pendingWaits, 1, "A start that keeps the directory must not satisfy the wait")
        history.recordStart(command: "pwd", directory: "/tmp")
        history.recordReady(code: 0, directory: "/etc")
        let result = try await waiter.value
        XCTAssertEqual(result.condition, "cwd_changed")
        XCTAssertEqual(result.cwd, "/etc")
    }
    func testLifecycleConditionTimesOutWithoutTrigger() async throws {
        let history = try TerminalObservation(id: "late", initialWorkspace: "/tmp")
        let started = ContinuousClock.now
        let result = try await history.wait(after: 0, timeout: 0.02, condition: .commandFinished)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.condition, "timeout")
        XCTAssertNil(result.command)
        XCTAssertLessThan(started.duration(to: ContinuousClock.now), .seconds(1))
        XCTAssertEqual(history.inspect().pendingWaits, 0)
    }
    func testTerminalWaitToolReturnsStructuredLifecycleResult() async throws {
        let catalog = TerminalObservations()
        let history = try catalog.create(id: "tool-life", workspace: "/tmp")
        let tools = try WorkspaceTools(root: FileManager.default.temporaryDirectory, observations: catalog)
        let waiter = Task { try await tools.execute(ToolCall(id: "w", name: "terminal_wait", arguments: "{\"terminal_id\":\"tool-life\",\"after\":\"0\",\"timeout_seconds\":\"2\",\"condition\":\"command_finished\"}")) }
        for _ in 0..<200 {
            if history.inspect().pendingWaits == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        history.recordStart(command: "ls", directory: "/tmp")
        history.recordReady(code: 0, directory: "/")
        let output = try await waiter.value.output
        XCTAssertFalse(output.contains("\u{1b}"))
        let result = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [String: Any]
        XCTAssertEqual(result["condition"] as? String, "command_finished")
        XCTAssertEqual(result["cwd"] as? String, "/")
        XCTAssertNil(result["bytes"])
        XCTAssertEqual(result["nextCursor"] as? Int, 0)
        let command = result["command"] as? [String: Any]
        XCTAssertEqual(command?["command"] as? String, "ls")
        XCTAssertEqual(command?["exitCode"] as? Int, 0)
        XCTAssertNotNil(command?["startedAt"] as? String)
    }
    func testLifecycleWaitKeepsPTYResponsive() async throws {
        let history = try TerminalObservation(id: "resp", initialWorkspace: "/tmp")
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, observation: history, segmented: true, onOutput: { _ in })
        defer { session.close() }
        let lifecycle = Task { try await history.wait(after: 0, timeout: 5, condition: .commandFinished) }
        for _ in 0..<250 {
            if history.inspect().pendingWaits == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try session.write(Data("printf 'RESPONSIVE\\n'\r".utf8))
        let result = try await lifecycle.value
        XCTAssertEqual(result.condition, "command_finished")
        XCTAssertTrue(result.command?.command?.contains("RESPONSIVE") == true)
        try session.write(Data("printf '\\nAFTER_WAIT\\n'\r".utf8))
        var sawAfter = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if history.commandHistory(limit: 16).contains(where: { $0.command?.contains("AFTER_WAIT") == true && $0.endedAt != nil }) { sawAfter = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(sawAfter)
        session.close()
        _ = await session.wait()
    }
    func testWaitConditionRawValueRejectsUnknownValues() async throws {
        XCTAssertNil(TerminalWaitCondition(rawValue: "foreground_idle"))
        XCTAssertEqual(TerminalWaitCondition(rawValue: "command_finished"), .commandFinished)
        XCTAssertEqual(TerminalWaitCondition(rawValue: "cwd_changed"), .cwdChanged)
        let catalog = TerminalObservations()
        _ = try catalog.create(id: "reject", workspace: "/tmp")
        let tools = try WorkspaceTools(root: FileManager.default.temporaryDirectory, observations: catalog)
        do {
            _ = try await tools.execute(ToolCall(id: "bad", name: "terminal_wait", arguments: "{\"terminal_id\":\"reject\",\"after\":\"0\",\"condition\":\"foreground_idle\"}"))
            XCTFail("Expected unknown condition to be rejected")
        } catch {}
    }
    func testForegroundPgidMatchesShellAtPromptAndTracksChild() async throws {
        let history = try TerminalObservation(id: "fg", initialWorkspace: "/tmp")
        let session = try PTYSession(workspace: FileManager.default.temporaryDirectory, observation: history, onOutput: { _ in })
        defer { session.close() }
        // forkpty returns before the child runs setsid/TIOCSCTTY, so tcgetpgrp on
        // the master reports no foreground group for a brief window. Poll until
        // the shell owns the terminal instead of sampling once; only then is the
        // value meaningful.
        var atPrompt: TerminalInfo?
        let promptDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < promptDeadline {
            let info = history.inspect()
            if info.foregroundPgid != nil { atPrompt = info; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let atPrompt else {
            // The platform never exposed a foreground process group; assert nothing.
            throw XCTSkip("The PTY never exposed a foreground process group in this environment")
        }
        XCTAssertEqual(atPrompt.foregroundPgid, session.shellPgid)
        XCTAssertFalse(atPrompt.foregroundBusy)
        try session.write(Data("sleep 5\r".utf8))
        var busy = false
        var child: TerminalInfo?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            child = history.inspect()
            if child?.foregroundBusy == true { busy = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(busy, "A foreground child should not share the shell process group")
        XCTAssertNotEqual(child?.foregroundPgid, session.shellPgid)
        try? session.interrupt()
        session.close(); _ = await session.wait()
    }
    func testTerminalInspectReportsForegroundState() async throws {
        let catalog = TerminalObservations()
        _ = try catalog.create(id: "fg-tool", workspace: "/tmp")
        let tools = try WorkspaceTools(root: FileManager.default.temporaryDirectory, observations: catalog)
        let output = try await tools.execute(ToolCall(id: "i", name: "terminal_inspect", arguments: "{}")).output
        let list = try JSONSerialization.jsonObject(with: Data(output.utf8)) as! [[String: Any]]
        XCTAssertEqual(list.first?["foregroundBusy"] as? Bool, false)
        XCTAssertNil(list.first?["foregroundPgid"])
        XCTAssertTrue(tools.definitions.first { $0.name == "terminal_inspect" }?.description.contains("foreground") == true)
    }
}
