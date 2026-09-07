# Architecture

Pocket DSH is a thin native client. Harness owns agent execution, tools, session history, and model configuration.

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

Each pane owns a store and follows its selected session through the Harness remote stream. Historical and streaming events fold into transcript rows. Signing configuration lives outside source code in an ignored local xcconfig.

## Optional Harness plugins

- [`dsh-voice`](../plugins/dsh-voice): authenticated audio relay and browser microphone UI. Configure `POCKET_DSH_ASR_URL` on the server; default `http://127.0.0.1:9000/asr`. No transcription model is bundled.
- [`dsh-images`](../plugins/dsh-images): agent image output support. See its README for installation and supported contract.

Plugin configuration belongs on the server. Do not install a plugin or restart a working Harness instance as part of a client build.

`TurnNotifications.swift` contains an experimental background implementation. It is not a reliable push service and is not advertised as a supported feature.
