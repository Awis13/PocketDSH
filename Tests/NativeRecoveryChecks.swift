import Foundation
import Darwin

struct CheckFailure: Error { let message: String }
func require(_ condition: Bool, _ message: String) throws { if !condition { throw CheckFailure(message: message) } }

final class RecoverySocket {
    let socket: URLSessionWebSocketTask
    init(port: Int, token: String) {
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        socket = URLSession.shared.webSocketTask(with: request); socket.resume()
    }
    func close() { socket.cancel(with: .goingAway, reason: nil) }
    func send(_ event: NativeCommand) async throws { try await socket.send(.string(String(decoding: JSONEncoder().encode(event), as: UTF8.self))) }
    func until(_ predicate: (NativeEvent) -> Bool) async throws -> [NativeEvent] {
        let timeout = Task { [socket] in
            do { try await Task.sleep(for: .seconds(60)); socket.cancel(with: .goingAway, reason: nil) } catch {}
        }
        defer { timeout.cancel() }
        var events: [NativeEvent] = []
        while true {
            let message = try await socket.receive()
            let data: Data
            switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: throw CheckFailure(message: "Unknown WebSocket frame") }
            let event = try JSONDecoder().decode(NativeEvent.self, from: data)
            try require(event.op != "error", event.text ?? "Host error")
            events.append(event)
            if predicate(event) { return events }
        }
    }
    func open(_ id: String) async throws -> [NativeEvent] {
        try await send(NativeCommand(op: "open", session: id))
        return try await until { $0.op == "synced" }
    }
    func command(_ text: String, session: String) async throws -> [NativeEvent] {
        try await send(NativeCommand(op: "input", session: session, bytes: Data((text + "\n").utf8)))
        var events = try await until { $0.op == "blockStart" }
        events += try await until { $0.op == "blockEnd" }
        return events
    }
}

@main struct NativeRecoveryChecks {
    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let endpoint = ProcessInfo.processInfo.environment["HARNESS_BASE_URL"],
              let model = ProcessInfo.processInfo.environment["HARNESS_MODEL"] else {
            throw CheckFailure(message: "Usage: recovery-checks HARNESS_BINARY ISOLATED_DIRECTORY; set HARNESS_BASE_URL and HARNESS_MODEL for your test provider")
        }
        let binary = CommandLine.arguments[1]
        let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let port = 8787, token = UUID().uuidString + UUID().uuidString
        let id = UUID().uuidString
        var host: Process?
        var clients: [RecoverySocket] = []
        defer {
            clients.forEach { $0.close() }
            if let host, host.isRunning { host.terminate(); host.waitUntilExit() }
        }
        func start() async throws -> RecoverySocket {
            let process = Process(); process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["--host", "--workspace", root.path, "--store", root.appendingPathComponent("events.sqlite").path]
            var env = ProcessInfo.processInfo.environment
            env["HARNESS_HOST_PORT"] = String(port); env["HARNESS_HOST_TOKEN"] = token
            env["HARNESS_BASE_URL"] = endpoint
            env["HARNESS_MODEL"] = model
            env.removeValue(forKey: "HARNESS_DISABLE_THINKING")
            process.environment = env
            let log = root.appendingPathComponent("host-\(UUID().uuidString).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log); process.standardOutput = handle; process.standardError = handle
            try process.run(); host = process
            try await Task.sleep(for: .milliseconds(600))
            try require(process.isRunning, "Host failed to start")
            let client = RecoverySocket(port: port, token: token); clients.append(client)
            return client
        }
        func output(_ events: [NativeEvent]) -> String { String(decoding: events.filter { $0.op == "pty" }.reduce(Data()) { $0 + ($1.bytes ?? Data()) }, as: UTF8.self) }
        let first = try await start()
        _ = try await first.open(id)
        let finished = try await first.command("printf '\\033[35mPERSIST_OK\\033[0m\\n'; cd /tmp", session: id)
        try require(output(finished).contains("\u{1B}[35mPERSIST_OK"), "ANSI bytes missing")
        try require(finished.last?.exitCode == 0, "Completed command failed")
        let requestID = UUID().uuidString
        let prompt = "Do not use tools. Reply with exactly REMEMBERED_OK."
        try await first.send(NativeCommand(op: "prompt", session: id, id: requestID, text: prompt, withTerminal: true))
        let answer = try await first.until { $0.op == "stage" && ["completed", "failed"].contains($0.stage ?? "") }
        try require(answer.filter { $0.op == "text" }.compactMap(\.text).joined().contains("REMEMBERED_OK"), "Model response missing")
        try await first.send(NativeCommand(op: "input", session: id, bytes: Data("printf RUNNING_OK; sleep 2; printf FINISHED_OFFLINE\\n\n".utf8)))
        _ = try await first.until { $0.op == "blockStart" }
        first.close()
        try await Task.sleep(for: .seconds(3))
        let second = RecoverySocket(port: port, token: token); clients.append(second)
        let replay = try await second.open(id)
        try require(output(replay).contains("FINISHED_OFFLINE"), "Detached command did not finish")
        try require(replay.filter { $0.op == "user" && $0.id == requestID }.count == 1, "Duplicated user admission")
        // Retry with changed terminal output: the host must keep the original context.
        try await second.send(NativeCommand(op: "prompt", session: id, id: requestID, text: prompt, withTerminal: true))
        let duplicate = try await second.until { $0.op == "accepted" }
        try require(!duplicate.contains { $0.op == "user" || $0.op == "text" }, "Retry reran an admitted request")
        print("PASS live reconnect: completed output, ANSI, shared history, idempotent request with changed terminal tail")
        let marker = root.appendingPathComponent("crashed.txt")
        let quoted = "'" + marker.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        try await second.send(NativeCommand(op: "input", session: id, bytes: Data(("printf once >> " + quoted + "; printf BEFORE_CRASH; sleep 30\n").utf8)))
        _ = try await second.until { $0.op == "pty" && String(decoding: $0.bytes ?? Data(), as: UTF8.self).contains("BEFORE_CRASH") }
        try await second.send(NativeCommand(op: "prompt", session: id, id: UUID().uuidString,
            text: "Do not call tools. Write 2000 numbered lines, each saying recovery stream check."))
        _ = try await second.until { $0.op == "text" }
        kill(host!.processIdentifier, SIGKILL); host!.waitUntilExit(); second.close()
        let third = try await start()
        try await third.send(NativeCommand(op: "list"))
        let list = try await third.until { $0.op == "sessions" }
        try require(list.last?.sessions?.contains { $0.id == id && $0.title.contains("PERSIST_OK") && !$0.running } == true, "Session metadata not restored")
        let restored = try await third.open(id)
        try require(restored.contains { $0.op == "blockEnd" && $0.failed == true && $0.exitCode == nil }, "Interrupted shell was not marked unknown")
        try require(restored.contains { $0.op == "stage" && $0.stage == "interrupted" }, "Interrupted model turn not closed")
        try require(restored.filter { $0.op == "user" && $0.id == requestID }.count == 1, "Request duplicated after crash")
        try require(restored.filter { $0.op == "text" }.compactMap(\.text).joined().contains("REMEMBERED_OK"), "Completed answer lost")
        try require(output(restored).contains("\u{1B}[35mPERSIST_OK"), "Completed ANSI output lost after crash")
        try await third.send(NativeCommand(op: "status", session: id))
        let status = try await third.until { $0.op == "status" }
        try require(status.last?.running == false, "Host automatically resumed old work")
        try require(try String(contentsOf: marker, encoding: .utf8) == "once", "Interrupted side effect was rerun")
        let fresh = try await third.command("pwd; printf NEW_SHELL_OK", session: id)
        try require(output(fresh).contains("/tmp") && output(fresh).contains("NEW_SHELL_OK"), "Fresh shell or cwd recovery failed")
        try await third.send(NativeCommand(op: "prompt", session: id, id: UUID().uuidString, text: "Do not use tools. Reply with exactly RECOVERY_CONTINUE_OK."))
        let continued = try await third.until { $0.op == "stage" && ["completed", "failed"].contains($0.stage ?? "") }
        try require(continued.filter { $0.op == "text" }.compactMap(\.text).joined().contains("RECOVERY_CONTINUE_OK"), "Agent cannot continue after interrupted turn")
        print("PASS SIGKILL recovery: partial stream, completed answer, unknown shell exit, no rerun, restored cwd, usable new shell")
        try JSONEncoder().encode(restored).write(to: root.appendingPathComponent("recovered-events.json"), options: .atomic)
        third.close(); host!.terminate(); host!.waitUntilExit()
        let fourth = try await start()
        let again = try await fourth.open(id)
        try require(again.filter { $0.op == "stage" && $0.stage == "interrupted" }.count == 1, "Recovery duplicated interrupted notices")
        print("PASS repeated restart: recovery is idempotent")
    }
}
