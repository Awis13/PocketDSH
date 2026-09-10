# Pocket DSH

Native SwiftUI/UIKit client for iPhone, iPad and Mac Catalyst, with two explicit backends: DeepSeek Harness Remote RPC and the experimental Swift Native Harness host. The host runs on macOS; iOS is a remote client.

- `PocketDSH/`: UI, transport, shared Shell/Chat presentation and themes.
- `NativeHarness/`: Swift 6 engine, SQLite journals, C/POSIX PTY bridge and CLI/host.
- `Shared/NativeWire.swift`: host/client protocol; the Swift package references it through a relative symlink.
- `Vendor/`: SwiftTerm library subset and Nerd Fonts symbols, with provenance and licenses.
- `project.yml`: canonical XcodeGen definition; regenerate the checked-in project after changes.

Run `sh scripts/check.sh` for offline protocol, Markdown, core, terminal and mocked voice checks. Node is used only for the optional DSH plugin tests, not the native runtime. Build the Mac Catalyst and generic iOS targets for UI changes. Live probes are opt-in; read their arguments and use isolated state/workspaces and your own provider configuration.

Shell and Chat are parallel presentations of the same session. Keep terminal output and agent activity visible in Shell. Enter runs shell input; Command+Enter asks the agent in place. Preserve existing Chat behavior, themes, pane focus and Command+W closing only the active pane.

Keep credentials in Keychain/environment or ignored local configuration. Never commit runtime databases, logs, private output, signing identities or host addresses. Do not restart production services for builds. The Rust terminal and `PagerTerminal/` are separate projects.

Current priorities and all research-gap statuses: `docs/ROADMAP.md`. Integration evidence and limits: `docs/NATIVE-CHAT-INTEGRATION.md`. Historical comparisons: `docs/FEATURE-PARITY-AUDIT.md`, `docs/WARP-FEATURE-AUDIT.md`, `docs/NATIVE-HARNESS-RESEARCH.md`. A DSH-backed feature is not proof of native-host support.
