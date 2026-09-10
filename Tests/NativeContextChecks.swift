import Foundation

private func ensure(_ condition: Bool, _ message: String = "Context check failed", line: UInt = #line) { precondition(condition, "Line \(line): " + message) }

@main struct NativeContextChecks {
    static func main() async throws {
        if CommandLine.arguments.count > 2 { try await live(); return }
        var transcript = NativeTranscript()
        transcript.apply(NativeEvent(op: "opened", session: "s"))
        ensure(!transcript.supportsCompaction)
        transcript.apply(NativeEvent(op: "opened", session: "s", capabilities: [NativeCompactionInfo.capability]))
        ensure(transcript.supportsCompaction)
        transcript.apply(NativeEvent(op: "user", session: "s", id: "u", text: "Keep this draft and history", sequence: 1))
        transcript.apply(NativeEvent(op: "blockStart", session: "s", id: "b", text: "htop", sequence: 2))
        let rows = transcript.rows
        let start = NativeCompactionInfo(id: "operation", state: "running")
        transcript.apply(NativeEvent(op: "compaction", session: "s", sequence: 3, compaction: start))
        let finish = NativeCompactionInfo(id: "operation", state: "completed")
        transcript.apply(NativeEvent(op: "compaction", session: "s", sequence: 4, compaction: finish))
        transcript.apply(NativeEvent(op: "compaction", session: "s", sequence: 3, compaction: start))
        transcript.apply(NativeEvent(op: "status", session: "s", compaction: start))
        transcript.apply(NativeEvent(op: "compaction", session: "other", compaction: start))
        ensure(transcript.compaction == finish && transcript.rows == rows && !transcript.rows.last!.complete)
        let maintenance = NativeRequestInfo(fields: ["requestID": .string("r"), "turnID": .string("t"), "purpose": .string("compaction"), "stage": .string("failed")])
        transcript.apply(NativeEvent(op: "request", session: "s", stage: "failed", request: maintenance))
        ensure(transcript.rows == rows && transcript.requests == [maintenance] && transcript.protocolNotices.isEmpty)
        let encoded = Data(#"{"op":"compaction","compaction":{"operationID":"o","state":"completed","future":{"x":[1,null]},"before":{"input":{"tokens":12345,"kind":"estimated"}},"after":{"input":{"tokens":5000,"kind":"estimated"}}}}"#.utf8)
        let event = try JSONDecoder().decode(NativeEvent.self, from: encoded)
        let copy = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(event))
        ensure(copy.compaction == event.compaction && copy.compaction!.detail.contains("≈"))
        ensure(NativeCompactionInfo.isEditorCommand(" /compact\n"))
        ensure(!NativeCompactionInfo.isEditorCommand("/compact", terminalRunning: true))
        ensure(!NativeCompactionInfo.isEditorCommand("/compact later"))
        transcript.apply(NativeEvent(op: "opened", session: "new"))
        ensure(transcript.compaction == nil && !transcript.supportsCompaction)
        print("PASS context controls: old host, receipt/replay, session isolation, raw TUI ownership and unchanged transcript")
    }
    static func live() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), phase = CommandLine.arguments[2]
        let config = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("connection.json")))
        var request = URLRequest(url: URL(string: config["endpoint"]!)!)
        request.setValue("Bearer " + config["token"]!, forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request); socket.resume()
        let timer = Task { try? await Task.sleep(for: .seconds(40)); if !Task.isCancelled { socket.cancel(with: .goingAway, reason: nil) } }
        defer { timer.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        func send(_ c: NativeCommand) async throws { try await socket.send(.data(JSONEncoder().encode(c))) }
        func until(_ end: (NativeEvent) -> Bool) async throws -> [NativeEvent] {
            var events: [NativeEvent] = []
            while true {
                let incoming = try await socket.receive()
                let data: Data
                switch incoming { case .data(let d): data=d; case .string(let s): data=Data(s.utf8); @unknown default: fatalError() }
                let e = try JSONDecoder().decode(NativeEvent.self, from: data)
                ensure(e.op != "error", e.text ?? "host error")
                events.append(e)
                if end(e) { return events }
            }
        }
        let scenario = phase == "replay" ? "crash" : phase
        let id = config[scenario]!, op = "compact-" + scenario
        try await send(NativeCommand(op: "open", session: id))
        let opened = try await until { $0.op == "synced" }
        ensure(opened.first?.capabilities?.contains(NativeCompactionInfo.capability) == true)
        var original = NativeTranscript(); opened.forEach { original.apply($0) }
        if phase == "replay" {
            ensure(original.compaction?.state == "interrupted")
            try await send(NativeCommand(op: "compact", session: id, id: op))
            let retry = try await until { $0.compaction?.id == op }
            ensure(retry.last?.compaction?.state == "interrupted")
            try await send(NativeCommand(op: "status", session: id))
            ensure(try await until { $0.op == "status" }.last?.running == false)
        } else if phase == "auto" {
            try await send(NativeCommand(op: "prompt", session: id, id: "auto-prompt", text: "continue"))
            let events = try await until { $0.op == "stage" && ["completed", "failed"].contains($0.stage ?? "") }
            ensure(events.last?.stage == "completed")
            ensure(events.contains { $0.compaction?.state == "completed" })
            ensure(events.filter { $0.op == "stage" && $0.stage == "completed" }.count == 1)
            ensure(events.filter { $0.op == "text" }.compactMap(\.text).joined() == "CONTINUED")
        } else {
            // Compaction must not interrupt a running command or write anything to its input.
            try await send(NativeCommand(op: "input", session: id, bytes: Data("printf C5_PTY_ALIVE; sleep 30\n".utf8)))
            _ = try await until { $0.op == "blockStart" && $0.text?.contains("C5_PTY_ALIVE") == true }
            _ = try await until { $0.op == "pty" && String(decoding: $0.bytes ?? Data(), as: UTF8.self).contains("C5_PTY_ALIVE") }
            try await send(NativeCommand(op: "compact", session: id, id: op))
            let started = try await until { $0.compaction?.id == op }
            ensure(started.last?.compaction?.isRunning == true)
            if phase == "cancel" || phase == "crash" {
                _ = try await until { $0.op == "request" && $0.request?.string("purpose") == "compaction" && $0.stage == "requesting" }
                if phase == "crash" { print("PASS crash boundary: summary in flight"); return }
                try await send(NativeCommand(op: "compact", session: id, id: "busy-id"))
                ensure(try await until { $0.op == "compactionRejected" }.last?.text == "BUSY")
                try await send(NativeCommand(op: "cancel", session: id))
            }
            let finished = try await until { $0.compaction?.id == op && $0.compaction?.isFinished == true }
            let receipt = finished.last!.compaction!
            ensure(receipt.state == (phase == "cancel" ? "cancelled" : phase == "unknown" ? "failed" : "completed"), receipt.detail)
            if phase == "unknown" { ensure(receipt.code == "CONTEXT_CAPACITY_UNKNOWN") }
            ensure(!finished.contains { $0.op == "blockEnd" || $0.op == "text" || $0.op == "user" || $0.op == "toolCall" })
            try await send(NativeCommand(op: "compact", session: id, id: op))
            ensure(try await until { $0.compaction?.id == op && $0.compaction?.isFinished == true }.last?.compaction == receipt)
            // Existing interrupt remains independent, and still ends the command.
            try await send(NativeCommand(op: "interrupt", session: id))
            _ = try await until { $0.op == "blockEnd" }
            try await send(NativeCommand(op: "open", session: id))
            let replay = try await until { $0.op == "synced" }
            var restored = NativeTranscript(); replay.forEach { restored.apply($0) }
            ensure(restored.compaction == receipt && restored.protocolNotices.isEmpty)
            ensure(restored.rows.filter { $0.kind != .shell && $0.kind != .notice } == original.rows.filter { $0.kind != .shell && $0.kind != .notice })
            try JSONEncoder().encode(Array(replay.drop(while: { $0.op != "opened" }))).write(to: root.appendingPathComponent(phase + "-events.json"))
            if phase == "manual" {
                try await send(NativeCommand(op: "prompt", session: id, id: "after-manual", text: "continue"))
                ensure(try await until { $0.op == "stage" && ["completed", "failed"].contains($0.stage ?? "") }.last?.stage == "completed")
            }
        }
        print("PASS live context controls: " + phase)
    }
}
