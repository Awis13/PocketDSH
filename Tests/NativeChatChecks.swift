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

        var edited = NativeTranscript()
        edited.apply(NativeEvent(op: "user", id: "req", text: "original text", sequence: 1))
        precondition(edited.rows.count == 1 && edited.rows[0].text == "original text")
        edited.apply(NativeEvent(op: "user", id: "req", text: "edited text", sequence: 2))
        precondition(edited.rows.count == 1 && edited.rows[0].text == "edited text",
                     "An edited queued request must reconcile its existing row, not duplicate it")
        print("PASS edited queue reconciliation: same request id updates the row in place")

        var queued = NativeTranscript()
        queued.apply(NativeEvent(op: "opened", session: "s", capabilities: [NativeQueueInfo.capability]))
        precondition(queued.supportsQueue)
        let snapshot = NativeQueueInfo(items: [
            NativeQueueItem(id: "a", preview: "first", placement: NativeQueueItem.queued, truncated: false),
            NativeQueueItem(id: "b", preview: "second", placement: NativeQueueItem.steering, truncated: true),
            NativeQueueItem(id: "", preview: "invalid", placement: NativeQueueItem.queued, truncated: false)
        ], omitted: 2)
        queued.apply(NativeEvent(op: "queue", session: "s", queue: snapshot))
        precondition(queued.queue.map { $0.id } == ["a", "b"], "Invalid queue items must be dropped")
        // Dropped invalid items fold into omitted so the displayed total still agrees.
        precondition(queued.queueOmitted == 3 && queued.queue.count + queued.queueOmitted == snapshot.count)
        precondition(queued.queue.first?.isSteering == false && queued.queue.last?.isSteering == true)
        queued.apply(NativeEvent(op: "queueAccepted", session: "s"))
        queued.apply(NativeEvent(op: "queueRejected", session: "s"))
        queued.apply(NativeEvent(op: "queueText", session: "s", id: "a", text: "full"))
        precondition(queued.protocolNotices.isEmpty, "Queue control events are not unsupported operations")
        // A malformed queue block keeps the last good snapshot instead of wiping it.
        queued.apply(NativeEvent(op: "queue", session: "s", queue: nil))
        precondition(queued.queue.map { $0.id } == ["a", "b"] && queued.queueOmitted == 3,
                     "A missing queue block must not clear a good snapshot")
        queued.apply(NativeEvent(op: "opened", session: "s", capabilities: [NativeQueueInfo.capability]))
        precondition(queued.queue.isEmpty && queued.queueOmitted == 0, "Reconnect clears stale queue state")
        let futureQueue = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"queue","session":"s","queue":{"items":[],"omitted":0},"futureQueueField":{"deep":[1,2,3]}}"#.utf8))
        precondition(futureQueue.queue?.items.isEmpty == true && futureQueue.extraFields["futureQueueField"] != nil,
                     "Unknown queue-adjacent fields must survive without an unsupported-operation notice")
        queued.apply(futureQueue)
        precondition(queued.protocolNotices.isEmpty)
        print("PASS queue folding: capability, placement, bounded snapshot, control events, reconnect reset and future fields")

        let fixture = Data(#"{"op":"stage","session":"metrics","sequence":1,"stage":"failed","request":{"requestID":"r1","turnID":"t1","purpose":"conversation","stage":"failed","code":"HTTP_400","elapsedMS":500,"budget":{"input":{"tokens":300,"kind":"estimated","source":"serializedBytes"},"outputReserve":100,"capabilities":{"capacity":{"tokens":1000,"source":"configured"},"inputCounting":"unsupported"}},"usage":{"promptTokens":300,"completionTokens":2,"cachedTokens":null},"future":{"apiKey":"PRIVATE_KEY","endpoint":"PRIVATE_ENDPOINT","prompt":"PRIVATE_PROMPT"}},"future":{"large":9007199254740993,"nested":[true,null,{"x":"y"}]}}"#.utf8)
        let decoded = try JSONDecoder().decode(NativeEvent.self, from: fixture)
        let encoded = try JSONEncoder().encode(decoded)
        let originalJSON = try JSONDecoder().decode(NativeJSON.self, from: fixture)
        let roundtripJSON = try JSONDecoder().decode(NativeJSON.self, from: encoded)
        precondition(roundtripJSON == originalJSON, "Unknown envelope/request fields must survive replay, including large integers")
        let info = decoded.request!
        precondition(info.fraction == 0.4 && info.remaining == 600 && info.inputKind == "estimated")
        precondition(info.tokens("usage.cachedTokens") == nil)
        precondition(!info.diagnosticExport.contains("PRIVATE_"), "Export must allowlist metadata, excluding raw extensions")
        let malformed = try JSONDecoder().decode(NativeRequestInfo.self, from: Data(#"{"requestID":"r","turnID":"t","budget":{"input":{"tokens":true,"kind":"exact"},"outputReserve":-1,"capabilities":{"capacity":{"tokens":0}}},"usage":{"promptTokens":1.5,"completionTokens":9007199254740992},"firstTextMS":-5}"#.utf8))
        precondition(malformed.inputTokens == nil && malformed.fraction == nil && malformed.reserve == nil)
        precondition(malformed.tokens("usage.promptTokens") == nil && malformed.tokens("usage.completionTokens") == nil)
        precondition(malformed.milliseconds("firstTextMS") == nil)
        let bad = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"stage","stage":"preparing","request":"future-format"}"#.utf8))
        precondition(bad.request == nil && bad.extraFields["request"] != nil, "New metadata format must not disconnect the client")
        var metrics = NativeTranscript()
        metrics.apply(NativeEvent(op: "opened", session: "metrics")); metrics.apply(decoded); metrics.apply(decoded)
        precondition(metrics.requests.count == 1 && metrics.requests[0] == info && metrics.rows.count == 1)
        metrics.apply(NativeEvent(op: "opened", session: "metrics")); metrics.apply(decoded)
        precondition(metrics.requests == [info], "Reconnect restores the completed request without duplication")
        for op in ["pty", "status", "synced", "completion", "terminalSize", "approval", "workspaceAction"] { metrics.apply(NativeEvent(op: op)) }
        precondition(metrics.protocolNotices.isEmpty, "Known PTY/control events are not unsupported operations")
        metrics.apply(NativeEvent(op: "stage", stage: "futureStage"))
        for n in 0..<30 { metrics.apply(NativeEvent(op: "future\(n)")) }
        precondition(metrics.protocolNotices.count == 8, "Unknown significant events need bounded visible diagnostic notes")
        metrics.apply(NativeEvent(op: "opened", session: "other")); metrics.apply(decoded)
        precondition(metrics.requests.isEmpty && metrics.rows.isEmpty && metrics.protocolNotices.isEmpty, "Late metrics cannot leak into another session")
        metrics.apply(NativeEvent(op: "stage", session: "other", stage: "requesting", sequence: 1))
        precondition(metrics.requests.isEmpty, "Old hosts without metadata must show unknown, not invented zeroes")
        print("PASS request metadata: lossless future fields, safe export, validated counts, session isolation, bounded protocol notes and replay")

        var presentation = TerminalPresentation()
        precondition(!presentation.isExpanded && !presentation.showsReturnControl && presentation.anchor == nil,
                     "The terminal starts inline without a return anchor")
        presentation.alternateBufferActivated(anchor: "block-1")
        precondition(presentation.isExpanded && presentation.alternateBufferActive)
        precondition(presentation.showsReturnControl && presentation.anchor == "block-1")
        presentation.alternateBufferActivated(anchor: "block-2")
        precondition(presentation.anchor == "block-2", "The newest TUI owns the return anchor")
        presentation.returnToTranscript()
        precondition(!presentation.isExpanded && presentation.alternateBufferActive,
                     "A manual return collapses the surface while the TUI still owns the alternate buffer")
        precondition(presentation.alternateBufferDeactivated() == false,
                     "Exiting after a manual return must not trigger a second collapse")
        precondition(!presentation.alternateBufferActive)
        var tui = TerminalPresentation()
        tui.alternateBufferActivated(anchor: "block-3")
        precondition(tui.alternateBufferDeactivated() == true,
                     "Leaving a TUI collapses the expanded surface")
        precondition(tui.mode == .inline && !tui.alternateBufferActive)
        precondition(tui.consumeAnchor() == "block-3" && tui.anchor == nil, "The return anchor is one-shot")
        precondition(tui.consumeAnchor() == nil && tui.alternateBufferDeactivated() == false,
                     "A deactivation without an active TUI is inert")
        var reset = TerminalPresentation()
        reset.alternateBufferActivated(anchor: "block-4")
        reset.reset()
        precondition(reset == TerminalPresentation(), "Reset clears every presentation field")
        print("PASS terminal presentation: alternate-buffer transitions, one-shot return anchor and reset")

        let single = PaneFocusNavigator.Node.pane("a")
        precondition(PaneFocusNavigator.next(from: "a", direction: .left, in: single) == nil)
        precondition(PaneFocusNavigator.next(from: "missing", direction: .right, in: single) == nil)
        let horizontal = PaneFocusNavigator.Node.split(.horizontal, .pane("a"), .pane("b"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: horizontal) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .left, in: horizontal) == "a")
        precondition(PaneFocusNavigator.next(from: "a", direction: .left, in: horizontal) == nil)
        precondition(PaneFocusNavigator.next(from: "b", direction: .right, in: horizontal) == nil)
        precondition(PaneFocusNavigator.next(from: "a", direction: .up, in: horizontal) == nil,
                     "A perpendicular direction inside a lone split has no target")
        let vertical = PaneFocusNavigator.Node.split(.vertical, .pane("a"), .pane("b"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .down, in: vertical) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .up, in: vertical) == "a")
        precondition(PaneFocusNavigator.next(from: "a", direction: .up, in: vertical) == nil)
        let row = PaneFocusNavigator.Node.split(.horizontal, .pane("a"), .split(.horizontal, .pane("b"), .pane("c")))
        precondition(row.panes == ["a", "b", "c"] && row.contains("c"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: row) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .left, in: row) == "a")
        precondition(PaneFocusNavigator.next(from: "b", direction: .right, in: row) == "c")
        precondition(PaneFocusNavigator.next(from: "c", direction: .right, in: row) == nil)
        let grid = PaneFocusNavigator.Node.split(.horizontal, .pane("left"), .split(.vertical, .pane("top"), .pane("bottom")))
        precondition(PaneFocusNavigator.next(from: "top", direction: .left, in: grid) == "left")
        precondition(PaneFocusNavigator.next(from: "bottom", direction: .left, in: grid) == "left")
        precondition(PaneFocusNavigator.next(from: "left", direction: .right, in: grid) == "top",
                     "Returning into a column prefers its first pane")
        precondition(PaneFocusNavigator.next(from: "top", direction: .down, in: grid) == "bottom")
        precondition(PaneFocusNavigator.next(from: "top", direction: .up, in: grid) == nil)
        let stackedRow = PaneFocusNavigator.Node.split(.vertical, .split(.horizontal, .pane("a"), .pane("b")), .pane("c"))
        precondition(PaneFocusNavigator.next(from: "c", direction: .up, in: stackedRow) == "b",
                     "Moving into a row prefers the pane nearest the positive edge")
        print("PASS pane focus navigator: single, horizontal, vertical, nested row, grid and edge tie-breaks")

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
