#if DEBUG
import Foundation

/// Offline fixtures for reproducible screenshots. Never included in Release builds.
extension PocketStore {
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
