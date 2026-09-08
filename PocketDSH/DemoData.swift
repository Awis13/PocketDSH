#if DEBUG
import Foundation

/// Offline fixtures for reproducible screenshots. Never included in Release builds.
extension PocketStore {
    /// Displays a captured NativeEvent replay in the actual Shell/Chat views.
    /// This debug-only mode creates no transport and never runs shell input.
    func loadNativeReplay(_ path: String) {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 4_194_305) ?? Data()
            guard data.count <= 4_194_304 else { throw HarnessError(message: "Preview exceeds 4 MiB") }
            let events = try JSONDecoder().decode([NativeEvent].self, from: data)
            guard let opened = events.first, opened.op == "opened", let id = opened.session else {
                throw HarnessError(message: "Preview requires a session replay beginning with opened")
            }
            endpoint = "ws://127.0.0.1:1"; connected = true; connecting = false; error = nil
            selectedID = id
            model = .object(["model": .string(opened.model ?? "Preview")])
            sessions = [HarnessSession(raw: .object(["sessionId": .string(id), "cwd": .string(opened.workspace ?? ""),
                "updatedAt": .number(Date().timeIntervalSince1970 * 1000), "running": .bool(false),
                "projections": .object(["values": .object(["title": .string("Request diagnostics · offline replay")])])]))]
            var transcript = NativeTranscript()
            let client = NativeClient(id: id, endpoint: endpoint, token: "")
            client.externalSend = { _ in }
            for event in events {
                transcript.apply(event)
                if ["opened", "synced", "pty", "blockStart", "blockEnd", "ptyExit", "shellReset", "terminalSize"].contains(event.op) { client.receive(event) }
            }
            for block in client.blocks { transcript.updateShell(block) }
            nativeShell = client; rows = transcript.rows
            nativeRequests = transcript.requests; nativeProtocolNotices = transcript.protocolNotices
        } catch { self.error = "Cannot load offline replay: " + error.localizedDescription }
    }

    func loadDemo() {
        endpoint = "https://harness.example.com"
        connected = true
        error = nil
        model = .object(["model": .string("Qwen · local")])
        let titles = ["A quieter workspace", "Review the streaming client", "Plan the next release"]
        sessions = titles.enumerated().map { index, title in
            HarnessSession(raw: .object([
                "sessionId": .string("demo-\(index)"), "cwd": .string("~/Projects/pocket-dsh"),
                "updatedAt": .number(Date().timeIntervalSince1970 * 1000 - Double(index * 60000)),
                "projections": .object(["values": .object(["title": .string(title)])])
            ]))
        }
        selectedID = sessions.first?.id
        rows = [
            TranscriptRow(id: "request", kind: .user, text: "Help me make this workspace feel like home. Keep it fast, quiet, and keyboard-first."),
            TranscriptRow(id: "reason", kind: .reasoning, text: "I’ll review the layout and shortcuts, then suggest a small set of changes that preserve the current workflow."),
            TranscriptRow(id: "tool", kind: .tool, text: "read_file", detail: "Sources/Workspace.swift\nInspected pane layout and keyboard commands."),
            TranscriptRow(id: "answer", kind: .assistant, text: """
            ## Your workspace, your way

            The layout is ready. You can keep a conversation open while another agent reviews code alongside it.

            | Action | Shortcut |
            | :--- | :--- |
            | Split side by side | ⌘ D |
            | Split top and bottom | ⌘ ⇧ D |
            | Close active pane | ⌘ W |

            Switch to **terminal mode** with `/view`, or find a model with `/model`. Themes, fonts, and colors are yours to change.

            A small interface. Room for the work.
            """)
        ]
    }
}
#endif
