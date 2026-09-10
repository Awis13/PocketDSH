# Architecture

Pocket DSH is a native client with two explicit backends. DeepSeek Harness owns execution through its Remote RPC contract. The included experimental Swift Native Harness owns execution through a separate authenticated WebSocket protocol. Selecting a backend does not replace the UI. Shell execution stays on a macOS host; the iOS client does not run local processes.

| Area | Files |
| --- | --- |
| RPC, cookies, WebSocket transport | `HarnessAPI.swift` |
| Wire types and transcript folding | `HarnessProtocol.swift` |
| Connection and session state | `PocketStore.swift` |
| Sessions, workspace, split panes | `HomeView.swift` |
| Conversation, editor, keyboard commands | `HarnessView.swift` |
| Markdown and change previews | `AssistantMarkdown.swift`, `MarkdownBlocks.swift` |
| Themes and theme editor | `Appearance.swift` |
| Attachments and recording | `ImageAttachments.swift`, `ImageViews.swift`, `VoiceRecorder.swift` |
| Offline screenshot fixtures (Debug only) | `DemoData.swift` |
| Native wire contract | `Shared/NativeWire.swift` |
| Native transport and transcript folding | `NativeChatConnection.swift`, `NativeClient.swift` |
| Shell surface, selection, find and attachments | `NativeTerminalView.swift`, `ShellBlockInteraction.swift`, `ShellBlockViews.swift` |
| ANSI palette and symbol font | `TerminalAppearance.swift`, `Vendor/SwiftTerm`, `Vendor/NerdFonts` |
| Swift agent loop, receipts, approvals, diagnostics | `NativeHarness/Sources/HarnessCore` |
| macOS host, ordered presentation and restart recovery | `NativeHarness/Sources/harness`, `PresentationJournal.swift` |

Native Shell and Chat render one ordered journal and share a draft/session. A persistent PTY feeds the live emulator; completed blocks retain bounded output and styles. The engine database and adjacent `.native.sqlite` presentation journal have distinct responsibilities and must be backed up together. Reconnect reconstructs output; host restart marks interrupted work without rerunning commands or restoring dead OS processes.

The headless engine uses Swift/Foundation, SQLite and a small in-tree C bridge. The client bundles a locally patched SwiftTerm library subset and Nerd Fonts symbols with notices. Optional eza runs on the host. `NativeWorkspace.swift` is an earlier experiment retained in source, not the application entry point. See [native integration](NATIVE-CHAT-INTEGRATION.md) for current implementation evidence and constraints.

Each pane owns a store and follows its selected session through the Harness remote stream. Historical and streaming events fold into transcript rows. Signing configuration lives outside source code in an ignored local xcconfig.

## Optional Harness plugins

- [`dsh-voice`](../plugins/dsh-voice): authenticated audio relay and browser microphone UI. Configure `POCKET_DSH_ASR_URL` on the server; default `http://127.0.0.1:9000/asr`. No transcription model is bundled.
- [`dsh-images`](../plugins/dsh-images): agent image output support. See its README for installation and supported contract.

Plugin configuration belongs on the server. Do not install a plugin or restart a working Harness instance as part of a client build.

`TurnNotifications.swift` contains an experimental background implementation. It is not a reliable push service and is not advertised as a supported feature.
