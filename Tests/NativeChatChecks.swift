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
        let quad = PaneFocusNavigator.Node.split(.horizontal,
            .split(.vertical, .pane("tl"), .pane("bl")),
            .split(.vertical, .pane("tr"), .pane("br")))
        precondition(PaneFocusNavigator.next(from: "bl", direction: .right, in: quad) == "br",
                     "A nested 2x2 move keeps the active pane's row instead of jumping to the top")
        precondition(PaneFocusNavigator.next(from: "tl", direction: .right, in: quad) == "tr")
        precondition(PaneFocusNavigator.next(from: "br", direction: .left, in: quad) == "bl")
        precondition(PaneFocusNavigator.next(from: "tr", direction: .left, in: quad) == "tl")
        precondition(PaneFocusNavigator.next(from: "bl", direction: .up, in: quad) == "tl")
        precondition(PaneFocusNavigator.next(from: "br", direction: .up, in: quad) == "tr")
        precondition(PaneFocusNavigator.next(from: "tl", direction: .down, in: quad) == "bl")
        precondition(PaneFocusNavigator.next(from: "tr", direction: .down, in: quad) == "br")
        precondition(PaneFocusNavigator.next(from: "tl", direction: .left, in: quad) == nil,
                     "The leftmost nested pane has no neighbour to its left")
        precondition(PaneFocusNavigator.next(from: "tr", direction: .right, in: quad) == nil)
        let empty = PaneFocusNavigator.Node.pane("only")
        precondition(PaneFocusNavigator.next(from: "only", direction: .right, in: empty) == nil)
        precondition(PaneFocusNavigator.next(from: "missing", direction: .up, in: empty) == nil)
        let duplicate = PaneFocusNavigator.Node.split(.horizontal, .pane("dup"), .pane("dup"))
        precondition(PaneFocusNavigator.next(from: "dup", direction: .right, in: duplicate) == "dup",
                     "Duplicate ids are resolved deterministically instead of crashing")
        precondition(PaneFocusNavigator.node(stacked: false, first: .pane("l"), second: .pane("r")) == .split(.horizontal, .pane("l"), .pane("r")),
                     "The layout's stacked flag maps to the navigator axis")
        precondition(PaneFocusNavigator.node(stacked: true, first: .pane("t"), second: .pane("b")) == .split(.vertical, .pane("t"), .pane("b")))
        print("PASS pane focus navigator: single, horizontal, vertical, nested row, grid, nested 2x2 and edge tie-breaks")

        // A split parallel to the move is a boundary, but a nearer boundary on
        // the active path must win first. Left-leaning nests used to jump past
        // the adjacent pane straight to the root sibling.
        let leftColumn2 = PaneFocusNavigator.Node.split(.vertical,
            .split(.vertical, .pane("a"), .pane("b")), .pane("c"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .down, in: leftColumn2) == "b",
                     "A left-leaning column must descend to its adjacent pane before crossing the root split")
        precondition(PaneFocusNavigator.next(from: "b", direction: .down, in: leftColumn2) == "c")
        precondition(PaneFocusNavigator.next(from: "c", direction: .down, in: leftColumn2) == nil)
        precondition(PaneFocusNavigator.next(from: "a", direction: .up, in: leftColumn2) == nil)
        precondition(PaneFocusNavigator.next(from: "b", direction: .up, in: leftColumn2) == "a")
        precondition(PaneFocusNavigator.next(from: "c", direction: .up, in: leftColumn2) == "b")
        precondition(PaneFocusNavigator.next(from: "a", direction: .left, in: leftColumn2) == nil,
                     "A pure column has no horizontal neighbour")
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: leftColumn2) == nil)
        let leftColumn3 = PaneFocusNavigator.Node.split(.vertical,
            .split(.vertical, .split(.vertical, .pane("x"), .pane("y")), .pane("z")), .pane("w"))
        precondition(PaneFocusNavigator.next(from: "x", direction: .down, in: leftColumn3) == "y",
                     "A 3-deep left-leaning column must not skip to the root sibling")
        precondition(PaneFocusNavigator.next(from: "y", direction: .down, in: leftColumn3) == "z")
        precondition(PaneFocusNavigator.next(from: "z", direction: .down, in: leftColumn3) == "w")
        precondition(PaneFocusNavigator.next(from: "w", direction: .down, in: leftColumn3) == nil)
        precondition(PaneFocusNavigator.next(from: "w", direction: .up, in: leftColumn3) == "z")
        precondition(PaneFocusNavigator.next(from: "z", direction: .up, in: leftColumn3) == "y")
        precondition(PaneFocusNavigator.next(from: "x", direction: .up, in: leftColumn3) == nil)
        let rightColumn2 = PaneFocusNavigator.Node.split(.vertical, .pane("a"),
            .split(.vertical, .pane("b"), .pane("c")))
        precondition(PaneFocusNavigator.next(from: "a", direction: .down, in: rightColumn2) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .down, in: rightColumn2) == "c")
        precondition(PaneFocusNavigator.next(from: "b", direction: .up, in: rightColumn2) == "a")
        precondition(PaneFocusNavigator.next(from: "c", direction: .up, in: rightColumn2) == "b")
        let rightColumn3 = PaneFocusNavigator.Node.split(.vertical, .pane("x"),
            .split(.vertical, .pane("y"), .split(.vertical, .pane("z"), .pane("w"))))
        precondition(PaneFocusNavigator.next(from: "x", direction: .down, in: rightColumn3) == "y")
        precondition(PaneFocusNavigator.next(from: "y", direction: .down, in: rightColumn3) == "z")
        precondition(PaneFocusNavigator.next(from: "z", direction: .down, in: rightColumn3) == "w")
        precondition(PaneFocusNavigator.next(from: "z", direction: .up, in: rightColumn3) == "y")
        precondition(PaneFocusNavigator.next(from: "w", direction: .up, in: rightColumn3) == "z")
        precondition(PaneFocusNavigator.next(from: "w", direction: .down, in: rightColumn3) == nil)

        let leftRow2 = PaneFocusNavigator.Node.split(.horizontal,
            .split(.horizontal, .pane("a"), .pane("b")), .pane("c"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: leftRow2) == "b",
                     "A left-leaning row must descend to its adjacent pane before crossing the root split")
        precondition(PaneFocusNavigator.next(from: "b", direction: .right, in: leftRow2) == "c")
        precondition(PaneFocusNavigator.next(from: "c", direction: .right, in: leftRow2) == nil)
        precondition(PaneFocusNavigator.next(from: "a", direction: .left, in: leftRow2) == nil)
        precondition(PaneFocusNavigator.next(from: "b", direction: .left, in: leftRow2) == "a")
        precondition(PaneFocusNavigator.next(from: "c", direction: .left, in: leftRow2) == "b")
        precondition(PaneFocusNavigator.next(from: "a", direction: .up, in: leftRow2) == nil)
        precondition(PaneFocusNavigator.next(from: "a", direction: .down, in: leftRow2) == nil)
        let leftRow3 = PaneFocusNavigator.Node.split(.horizontal,
            .split(.horizontal, .split(.horizontal, .pane("x"), .pane("y")), .pane("z")), .pane("w"))
        precondition(PaneFocusNavigator.next(from: "x", direction: .right, in: leftRow3) == "y",
                     "A 3-deep left-leaning row must not skip to the root sibling")
        precondition(PaneFocusNavigator.next(from: "y", direction: .right, in: leftRow3) == "z")
        precondition(PaneFocusNavigator.next(from: "z", direction: .right, in: leftRow3) == "w")
        precondition(PaneFocusNavigator.next(from: "w", direction: .right, in: leftRow3) == nil)
        precondition(PaneFocusNavigator.next(from: "w", direction: .left, in: leftRow3) == "z")
        precondition(PaneFocusNavigator.next(from: "x", direction: .left, in: leftRow3) == nil)
        let rightRow2 = PaneFocusNavigator.Node.split(.horizontal, .pane("a"),
            .split(.horizontal, .pane("b"), .pane("c")))
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: rightRow2) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .right, in: rightRow2) == "c")
        precondition(PaneFocusNavigator.next(from: "c", direction: .left, in: rightRow2) == "b")
        precondition(PaneFocusNavigator.next(from: "c", direction: .right, in: rightRow2) == nil)
        let rightRow3 = PaneFocusNavigator.Node.split(.horizontal, .pane("x"),
            .split(.horizontal, .pane("y"), .split(.horizontal, .pane("z"), .pane("w"))))
        precondition(PaneFocusNavigator.next(from: "x", direction: .right, in: rightRow3) == "y")
        precondition(PaneFocusNavigator.next(from: "y", direction: .right, in: rightRow3) == "z")
        precondition(PaneFocusNavigator.next(from: "z", direction: .right, in: rightRow3) == "w")
        precondition(PaneFocusNavigator.next(from: "z", direction: .left, in: rightRow3) == "y")
        precondition(PaneFocusNavigator.next(from: "w", direction: .left, in: rightRow3) == "z")

        // Mixed leaning: the active child is a ridge of the other axis, so the
        // move has to descend through it before crossing.
        let mixedColumn = PaneFocusNavigator.Node.split(.vertical,
            .split(.horizontal, .pane("a"), .pane("b")), .pane("c"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .down, in: mixedColumn) == "c")
        precondition(PaneFocusNavigator.next(from: "b", direction: .down, in: mixedColumn) == "c")
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: mixedColumn) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .up, in: mixedColumn) == nil)
        let mixedRow = PaneFocusNavigator.Node.split(.horizontal,
            .split(.vertical, .pane("a"), .pane("b")), .pane("c"))
        precondition(PaneFocusNavigator.next(from: "a", direction: .right, in: mixedRow) == "c")
        precondition(PaneFocusNavigator.next(from: "b", direction: .right, in: mixedRow) == "c")
        precondition(PaneFocusNavigator.next(from: "a", direction: .down, in: mixedRow) == "b")
        precondition(PaneFocusNavigator.next(from: "b", direction: .up, in: mixedRow) == "a")

        // A perpendicular tie (the active pane's center is exactly on the
        // boundary) resolves deterministically to the first child.
        let perpendicularTie = PaneFocusNavigator.Node.split(.horizontal, .pane("solo"),
            .split(.vertical, .pane("first"), .pane("second")))
        precondition(PaneFocusNavigator.next(from: "solo", direction: .right, in: perpendicularTie) == "first",
                     "A perpendicular boundary tie resolves to the first pane")
        precondition(PaneFocusNavigator.next(from: "first", direction: .left, in: perpendicularTie) == "solo")
        precondition(PaneFocusNavigator.next(from: "second", direction: .left, in: perpendicularTie) == "solo")

        // Single pane behaves as a workspace with nowhere to go in any direction.
        let singlePane = PaneFocusNavigator.Node.pane("only")
        for direction in PaneFocusDirection.allCases {
            precondition(PaneFocusNavigator.next(from: "only", direction: direction, in: singlePane) == nil,
                         "A single pane has no neighbour in any direction")
            precondition(PaneFocusNavigator.next(from: "missing", direction: direction, in: singlePane) == nil,
                         "An absent pane never resolves")
        }

        // Duplicate ids stay deterministic rather than crashing or looping: the
        // active path resolves through the first matching subtree.
        let duplicateColumn = PaneFocusNavigator.Node.split(.vertical,
            .split(.vertical, .pane("dup"), .pane("mid")), .pane("dup"))
        precondition(PaneFocusNavigator.next(from: "dup", direction: .down, in: duplicateColumn) == "mid",
                     "Duplicate ids must resolve deterministically along the active path")
        let duplicateRow = PaneFocusNavigator.Node.split(.horizontal,
            .split(.horizontal, .pane("dup"), .pane("mid")), .pane("dup"))
        precondition(PaneFocusNavigator.next(from: "dup", direction: .right, in: duplicateRow) == "mid",
                     "Duplicate ids in a row resolve deterministically")
        print("PASS pane focus left-leaning nesting: 2/3-deep columns and rows, both leanings, ties, single and duplicate ids")

        var diffs = NativeTranscript()
        diffs.apply(NativeEvent(op: "opened", session: "s", capabilities: [NativeDiffInfo.capability]))
        precondition(diffs.supportsDiff)
        let diffInfo = NativeDiffInfo(base: "worktree", resolvedBase: nil, files: [
            NativeDiffFile(path: "a.txt", oldPath: nil, status: "modified", binary: false, additions: 1, deletions: 1,
                           truncated: false, hunks: [NativeDiffHunk(path: "a.txt", header: "@@ -1 +1 @@", oldText: "old", newText: "new")])
        ], truncated: false, error: nil)
        diffs.apply(NativeEvent(op: "diff", session: "s", diff: diffInfo))
        precondition(diffs.diff?.files.first?.hunks.first?.newText == "new")
        precondition(diffs.protocolNotices.isEmpty, "A diff event is a supported operation, not an unrecognized one")
        diffs.apply(NativeEvent(op: "opened", session: "s", capabilities: [NativeDiffInfo.capability]))
        precondition(diffs.diff == nil && diffs.supportsDiff, "Reconnect clears the previous diff but keeps the capability")
        let huge = NativeDiffInfo(base: "HEAD", files: [
            NativeDiffFile(path: "big", oldPath: nil, status: "modified", binary: false, additions: 0, deletions: 0,
                           truncated: false, hunks: [NativeDiffHunk(path: "big", header: "", oldText: "", newText: String(repeating: "x", count: 50_000))])
        ], truncated: false, error: nil)
        diffs.apply(NativeEvent(op: "diff", session: "s", diff: huge))
        precondition((diffs.diff?.files.first?.hunks.first?.newText.utf8.count ?? 0) <= 16_384 && diffs.diff?.truncated == true,
                     "An oversized host payload is re-clamped on the client")
        let futureDiff = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"diff","session":"s","diff":{"base":"worktree","files":[]},"futureDiffField":{"deep":[1,2,3]}}"#.utf8))
        precondition(futureDiff.diff?.base == "worktree" && futureDiff.extraFields["futureDiffField"] != nil)
        let roundtripDiff = try JSONDecoder().decode(NativeEvent.self, from: JSONEncoder().encode(futureDiff))
        precondition(roundtripDiff.extraFields["futureDiffField"] == futureDiff.extraFields["futureDiffField"],
                     "Unknown diff-adjacent fields survive replay")
        precondition(NativeDiffInfo.isValidBase("HEAD") && NativeDiffInfo.isValidBase("origin/main"))
        precondition(!NativeDiffInfo.isValidBase("../../etc") && !NativeDiffInfo.isValidBase("a b") && !NativeDiffInfo.isValidBase("$(x)"))
        print("PASS native diff: capability, fold, bounds, reconnect reset, unknown fields and base validation")

        var inline = NativeTranscript()
        inline.apply(NativeEvent(op: "toolCall", id: "edit", text: "edit_file", sequence: 1, arguments: #"{"path":"a.txt","old_text":"old","new_text":"new"}"#))
        inline.apply(NativeEvent(op: "toolResult", id: "edit", text: "Updated a.txt", sequence: 2, failed: false,
                                 toolDiffs: [NativeInlineDiffHunk(path: "a.txt", oldText: "old", newText: "new")]))
        let inlineRow = inline.rows.first { $0.kind == .tool }
        precondition(inlineRow?.diffs.count == 1, "A native tool result carries its inline diff into the row")
        precondition(inlineRow?.diffs.first?["path"].string == "a.txt")
        precondition(inlineRow?.diffs.first?["oldText"].string == "old")
        precondition(inlineRow?.diffs.first?["newText"].string == "new")
        inline.apply(NativeEvent(op: "toolCall", id: "add", text: "edit_file", sequence: 3))
        inline.apply(NativeEvent(op: "toolResult", id: "add", text: "Updated b.txt", sequence: 4,
                                 toolDiffs: [NativeInlineDiffHunk(path: "b.txt", oldText: nil, newText: "added")]))
        precondition(inline.rows.last { $0.kind == .tool }?.diffs.first?["oldText"] == .null,
                     "A pure insertion keeps its null oldText so it renders as an insertion")
        inline.apply(NativeEvent(op: "toolResult", id: "edit", text: "Updated a.txt", sequence: 5, failed: false))
        precondition(inline.rows.first { $0.id == "tool-edit" }?.diffs.count == 1,
                     "A later result without a diff keeps the row's existing diff")
        print("PASS native inline diff: fold into row.diffs, insertion null oldText, missing payload keeps prior")

        var hugeInline = NativeTranscript()
        hugeInline.apply(NativeEvent(op: "toolCall", id: "big", text: "edit_file", sequence: 1))
        hugeInline.apply(NativeEvent(op: "toolResult", id: "big", text: "Updated", sequence: 2,
                                     toolDiffs: [NativeInlineDiffHunk(path: "big", oldText: nil, newText: String(repeating: "x", count: 50_000))]))
        precondition((hugeInline.rows.first { $0.kind == .tool }?.diffs.first?["newText"].string.utf8.count ?? 0) <= 16_384,
                     "An oversized native inline diff is re-clamped on the client")
        let futureInline = try JSONDecoder().decode(NativeEvent.self, from: Data(#"{"op":"toolResult","id":"c","toolDiffs":[{"path":"a","oldText":null,"newText":"x"}],"futureInlineField":{"deep":[1]}}"#.utf8))
        precondition(futureInline.toolDiffs?.first?.newText == "x" && futureInline.extraFields["futureInlineField"] != nil,
                     "Unknown fields beside an inline diff survive replay")
        var futureRow = NativeTranscript()
        futureRow.apply(NativeEvent(op: "toolCall", id: "c", text: "edit_file", sequence: 1))
        futureRow.apply(futureInline)
        precondition(futureRow.protocolNotices.isEmpty, "An additive inline diff is not an unsupported operation")
        print("PASS native inline diff bounds: client re-clamp, additive fields and no protocol notices")

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
