<p align="center">
  <img src="docs/images/icon.png" width="96" alt="Pocket DSH icon">
</p>
<h1 align="center">Pocket DSH</h1>
<p align="center">Your agent. Your server. Your workspace.</p>
<p align="center">A native SwiftUI client for DeepSeek Harness on iPhone, iPad, and Mac.</p>

![Pocket DSH on Mac — Dracula theme, terminal mode](docs/images/mac-terminal.jpg)

Pocket DSH brings your Harness sessions into a keyboard-friendly workspace. Start a task on your Mac, continue on your iPad, and check in from your phone. The agent runs on your Harness server; the client stays focused on the conversation.

## Make room for the work

- **Chat or terminal.** Switch with `/view`: a familiar conversation layout or a full-width, monospaced transcript.
- **Multiple agents on one screen.** Split panes on iPad and Mac, each with its own session. Hide the sidebar when you want more space.
- **A keyboard-first workflow.** Send with Enter, use Shift+Enter for a newline, search models with `/model`, and start in the default workspace with `/new`.
- **Readable output.** Markdown tables, code, expandable tool details, change previews, images, and collapsible reasoning. Streaming follows the bottom until you scroll away.
- **Voice and pictures.** Attach images, or hold to talk, release to send, and swipe to cancel. Voice transcription uses an optional server plugin.
- **Make it yours.** Dracula, Nord, pixel and neon themes, plus a theme editor with custom colors, typography, and JSON import/export.

<table>
<tr><td><img src="docs/images/ipad-chat.png" alt="Chat mode on iPad"></td><td><img src="docs/images/iphone.png" alt="Pocket DSH on iPhone"></td></tr>
<tr><td>Chat mode · Nord</td><td>iPhone · Dracula</td></tr>
</table>

Screenshots show the real app with offline demonstration data, not a live user's conversations.

## Run it

You need a running **DeepSeek Harness** server. This client targets the Remote RPC/WebSocket contract used by DSH **0.1.2-rc.1**; it is not a standalone model runner.

1. Open `PocketDSH.xcodeproj` in Xcode. The source project definition is `project.yml` (regenerate with `xcodegen generate` after changing it).
2. Select the PocketDSH scheme and an iPhone/iPad simulator or **My Mac (Mac Catalyst)** destination.
3. For physical devices, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set your development team. This file stays local.
4. Run the app, open **Connection**, and paste the sign-in URL supplied by your Harness server.

Use a reachable HTTPS address for remote access. A private network such as Tailscale works well; keep the sign-in token when replacing a loopback hostname. Credentials are stored in Keychain. Model API keys remain on the Harness server.

See [installation and signing](docs/INSTALL.md) for device builds and AltStore packaging, and [architecture](docs/ARCHITECTURE.md) for the code map and optional plugins.

## Keyboard shortcuts

| Action | Shortcut |
| :--- | :--- |
| Send / insert newline | Enter / Shift+Enter |
| Split side by side | ⌘D |
| Split top and bottom | ⌘⇧D |
| Close active pane | ⌘W |
| Choose a model | `/model` |
| Switch chat / terminal | `/view` |
| New task in default workspace | `/new` |
| Complete a slash command | Tab or Enter |

Closing a pane leaves its agent running on the server. The last pane stays open.

## Development

No third-party Swift packages are required. Build with a current Xcode SDK; the deployment target is iOS 17. Some scrolling and material effects use newer system APIs with fallbacks.

```sh
./scripts/check.sh        # Protocol, Markdown, and voice relay checks; Xcode + Node required
./scripts/build-mac.sh    # Build and verify a signed Mac Catalyst app
```

Live integration checks are opt-in and require your own Harness instance. See [contributing](CONTRIBUTING.md).

## Status and boundaries

This is an independently developed personal client, being shared as an early project. It is not affiliated with DeepSeek or Apple. The Mac version uses **Mac Catalyst**. Glass styling uses system materials where available; it does not make the entire window transparent to other applications. Reliable background push notifications are not shipped. Voice needs the optional relay and your own transcription service.

The Rust terminal client is a separate project and is not included here.
