import Foundation

@main struct NativeChatChecks {
    static func main() async throws {
        var transcript = NativeTranscript()
        let stream = [
            NativeEvent(op: "opened"),
            NativeEvent(op: "user", id: "request", text: "Read a file", sequence: 1),
            NativeEvent(op: "reasoning", text: "Checking", sequence: 2),
            NativeEvent(op: "reasoning", text: " files", sequence: 3),
            NativeEvent(op: "stage", stage: "modelCompleted", sequence: 4),
            NativeEvent(op: "toolCall", id: "call", text: "read_file", sequence: 5, arguments: "{\"path\":\"fixture.txt\"}"),
            NativeEvent(op: "toolResult", id: "call", text: "file contents", sequence: 6, failed: false),
            NativeEvent(op: "text", text: "Answer", sequence: 7),
            NativeEvent(op: "stage", stage: "completed", sequence: 8)
        ]
        stream.forEach { transcript.apply($0) }
        precondition(transcript.rows.count == 4)
        precondition(transcript.rows[1].text == "Checking files")
        precondition(transcript.rows[2].detail.contains("file contents") && transcript.rows[2].complete)
        precondition(transcript.rows.allSatisfy(\.complete))
        let expected = transcript.rows
        stream.dropFirst().forEach { transcript.apply($0) }
        precondition(transcript.rows == expected, "Duplicate replay must not append deltas")
        stream.forEach { transcript.apply($0) }
        precondition(transcript.rows == expected, "Reconnect must recreate identical rows")
        transcript.apply(NativeEvent(op: "stage", stage: "cancelled", sequence: 9))
        precondition(transcript.rows.last?.text == "Response stopped")
        print("PASS native row folding: reasoning, tool details, completion, replay and cancellation")
        var mixed = NativeTranscript()
        let events = [
            NativeEvent(op: "opened"),
            NativeEvent(op: "blockStart", id: "ls", text: "ls", workspace: "/tmp", sequence: 1),
            NativeEvent(op: "user", id: "ask", text: "Explain", sequence: 2),
            NativeEvent(op: "text", text: "The", sequence: 3),
            NativeEvent(op: "blockEnd", sequence: 4, exitCode: 0),
            NativeEvent(op: "text", text: " files", sequence: 5),
            NativeEvent(op: "blockStart", id: "next", text: "sleep 1", workspace: "/tmp", sequence: 6),
            NativeEvent(op: "stage", stage: "completed", sequence: 7)
        ]
        events.forEach { mixed.apply($0) }
        precondition(mixed.rows.map(\.kind) == [.shell, .user, .assistant, .shell])
        precondition(mixed.rows[2].text == "The files", "PTY events must not split agent deltas")
        precondition(mixed.rows[0].complete && !mixed.rows[3].complete, "Agent completion must not finish a shell command")
        let mixedRows = mixed.rows
        events.forEach { mixed.apply($0) }
        precondition(mixed.rows == mixedRows, "Both presentations must replay the same ordered history")
        var block = NativeBlock(id: "ls", command: "ls", directory: "/tmp", preview: "src  README.md", exitCode: 0, finished: true)
        block.styledOutput = [NativeStyledRun(text: "src", foreground: 0xbd93f9), NativeStyledRun(text: "  README.md")]
        mixed.updateShell(block)
        precondition(mixed.rows[0].shell == block && mixed.rows[1].text == "Explain")
        print("PASS shared history: interleaved shell and agent, independent lifecycle, styled output, identical replay")
        mixed.apply(NativeEvent(op: "blockEnd", sequence: 8, failed: true))
        mixed.apply(NativeEvent(op: "stage", text: "Interrupted by host restart", stage: "interrupted", sequence: 9))
        mixed.apply(NativeEvent(op: "shellReset", text: "New shell", sequence: 10))
        precondition(mixed.rows[3].shell?.interrupted == true && mixed.rows[3].shell?.exitCode == nil)
        precondition(mixed.rows[4].kind == .notice && mixed.rows[4].text == "Interrupted by host restart")
        precondition(mixed.rows[5].text == "New shell")
        print("PASS recovery rows: interrupted command, unknown exit code, and restart notices")
        var live = NativeTranscript()
        live.apply(NativeEvent(op: "toolCall", id: "streamed-shell", text: "shell", sequence: 1, arguments: #"{"command":"printf 'Привет'"}"#))
        let utf8 = Array("Привет".utf8)
        live.apply(NativeEvent(op: "shellOutput", text: "stdout", bytes: Data(utf8.prefix(3)), sequence: 2))
        live.apply(NativeEvent(op: "shellOutput", text: "stdout", bytes: Data(utf8.dropFirst(3)), sequence: 3))
        precondition(live.rows[0].detail.hasSuffix("Привет") && !live.rows[0].complete, "Agent shell output must stream before tool completion, preserving split UTF-8")
        live.apply(NativeEvent(op: "toolResult", id: "streamed-shell", text: #"{"stdout":"Привет","stderr":"","exitCode":0,"outcome":"completed"}"#, sequence: 4))
        precondition(live.rows[0].detail.contains("exit 0") && live.rows[0].complete)
        precondition(live.rows[0].detail.components(separatedBy: "\n\n").last?.components(separatedBy: "Привет").count == 2, "Final result replaces the live preview rather than duplicating output")
        print("PASS agent commands: live output, split UTF-8, readable final result without duplication")
        var attached = NativeTranscript()
        let context = ShellContextAttachment(block: NativeBlock(id: "failed-build", command: "make", directory: "/tmp", preview: "ERROR missing_fixture", exitCode: 1, finished: true))
        let question = ShellPromptContent(question: "Explain this failure", attachments: [context])
        let sent = NativeEvent(op: "user", id: "attached-question", text: question.text, sequence: 1)
        attached.apply(sent)
        precondition(attached.rows.count == 1 && attached.rows[0].text == question.question,
                     "Both presentations must show the question without the transport envelope")
        precondition(attached.rows[0].detail == question.readableContext && attached.rows[0].detail.contains("Exit 1"),
                     "The exact sent context and exit status must remain inspectable in history")
        let sentRows = attached.rows
        attached.apply(sent)
        precondition(attached.rows == sentRows, "Acknowledgement replay must not duplicate attached questions")
        attached.apply(NativeEvent(op: "opened")); attached.apply(sent)
        precondition(attached.rows == sentRows, "Reconnect must restore the same question and captured context")
        print("PASS attached context: readable question, exact sent excerpt and idempotent replay")
        guard CommandLine.arguments.count > 1 else { return }
        let config = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let id = UUID().uuidString
        var request = URLRequest(url: URL(string: config["endpoint"]!)!)
        request.setValue("Bearer " + config["token"]!, forHTTPHeaderField: "Authorization")
        let ws = URLSession.shared.webSocketTask(with: request); ws.resume()
        let timeout = Task { try? await Task.sleep(for: .seconds(90)); ws.cancel(with: .goingAway, reason: nil) }
        defer { timeout.cancel(); ws.cancel(with: .goingAway, reason: nil) }
        func send(_ command: NativeCommand) async throws { try await ws.send(.data(JSONEncoder().encode(command))) }
        func receive() async throws -> NativeEvent {
            let msg = try await ws.receive()
            let data: Data
            switch msg { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: fatalError() }
            let event = try JSONDecoder().decode(NativeEvent.self, from: data)
            if event.op == "error" { throw HarnessError(message: event.text ?? "Host error") }
            return event
        }
        try await send(NativeCommand(op:"list"))
        let listed = try await receive(); precondition(listed.op == "sessions")
        try await send(NativeCommand(op:"open", session:id))
        while try await receive().op != "synced" {}
        func turn(_ text: String, decision: Bool?, stop: Bool = false) async throws -> [NativeEvent] {
            try await send(NativeCommand(op:"prompt", session:id, id:UUID().uuidString, text:text))
            var events:[NativeEvent] = []
            while true {
                let e = try await receive(); events.append(e)
                if e.op == "approval", let a = e.approval {
                    if stop { try await send(NativeCommand(op:"cancel", session:id)) }
                    else { try await send(NativeCommand(op:"approval", session:id, id:a.id, allow:decision ?? false)) }
                }
                if e.op == "stage", ["completed","cancelled","failed"].contains(e.stage ?? "") { return events }
            }
        }
        let read = try await turn("Read fixture.txt using read_file and quote its contents. Do not use shell.", decision:nil)
        precondition(read.contains { $0.op == "reasoning" }, "Home Rig should provide separate reasoning")
        precondition(!read.filter { $0.op == "text" }.compactMap(\.text).joined().contains("</think>"))
        precondition(read.contains { $0.op == "toolCall" } && read.contains { $0.op == "toolResult" && ($0.text ?? "").contains("BRIDGE_READ_OK") })
        let allow = try await turn("Use shell to execute exactly: printf 'BRIDGE_ALLOW_OK'. Do not use any other tool.", decision:true)
        precondition(allow.contains { $0.op == "approval" } && allow.contains { $0.op == "toolResult" && ($0.text ?? "").contains("BRIDGE_ALLOW_OK") })
        let deny = try await turn("Use shell to execute exactly: printf 'BRIDGE_DENY_TEST'. If rejected, stop and report the rejection; never retry.", decision:false)
        precondition(deny.contains { $0.op == "approval" })
        precondition(deny.contains { $0.op == "toolResult" && ($0.text ?? "").lowercased().contains("denied") })
        let stop = try await turn("Use shell to execute exactly: printf 'BRIDGE_CANCEL_TEST'.", decision:nil, stop:true)
        precondition(stop.contains { $0.op == "stage" && $0.stage == "cancelled" })
        try await send(NativeCommand(op:"open", session:id))
        var replay = NativeTranscript()
        while true { let e = try await receive(); replay.apply(e); if e.op == "synced" { break } }
        precondition(replay.rows.contains { $0.kind == .tool && $0.detail.contains("BRIDGE_READ_OK") })
        precondition(replay.rows.contains { $0.text == "Response stopped" })
        print("PASS live Qwen: read, rich tool result, approval allow/reject, cancellation and replay into existing chat rows")
    }
}
