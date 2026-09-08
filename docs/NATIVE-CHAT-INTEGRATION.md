# Native Harness in the existing Pocket DSH chat

The normal `HomeView` / `DesktopHomeView` / `HarnessView` remain the only application entry points. Native Harness is a connection type, not an alternate interface. The earlier `NativeWorkspaceView` experiment is not routed into the application.

## Connection

Choose **Native Harness** in Connection and paste a `ws://127.0.0.1:PORT?token=TOKEN` launch URL on the Mac, or an authenticated `wss://` endpoint through a separately configured secure tunnel. Only loopback addresses allow unencrypted WebSockets. The query token is removed before saving the endpoint and is stored in Keychain. No model credentials are sent to the client.

Run the Swift host with `harness --host --workspace PATH --store DATABASE`, and set `HARNESS_BASE_URL`, `HARNESS_MODEL`, `HARNESS_HOST_TOKEN` (at least 32 bytes), and optionally `HARNESS_HOST_PORT` (default 8768). It currently binds to loopback only. The development instance for this integration uses port 8769 and workspace `output/native-chat`, separately from the older terminal experiment and production DSH.

For the current Home Rig Qwen server, leave `HARNESS_DISABLE_THINKING` unset. Live checks on September 8 found that forcing `enable_thinking=false` could leak a closing think marker and repeat the answer in content. The default server template emits proper `reasoning_content` and `content` separately.

## Implemented

- Host session list, creation in the host workspace, selection and independent split-pane sessions.
- Existing themes, chat/terminal-style input, Markdown tables, composer focus and shortcuts.
- Incremental text and reasoning through the existing transcript renderer.
- Tool name, arguments, final result and failure state through existing tool cards.
- Existing permission cards and allow-once/reject keyboard actions; host acknowledges the decision.
- Cancellation and a stopped marker; outstanding permissions disappear when the turn ends.
- Ordered SQLite presentation journal on reconnect and host restart, including raw PTY bytes. Duplicate deltas are ignored.
- Prompt admission is persisted before the user event is published. The composer clears on host acknowledgement, not merely on socket send.

## Explicit preview boundaries

Native host supports eight instantiated shells per launch and one attached client per session. Saved sessions remain discoverable across host restarts and are opened on demand. Opening an old session creates a new shell, restoring its last known directory when available; shell environment variables and running OS processes do not survive host termination. A missing selected session is reported, never silently replaced.

Native image input, voice transcription, model switching, full-access policy, steer action, rich diffs and background notifications are not wired yet. Unsupported input controls are disabled. Existing DSH behavior is preserved. The desktop and iPad Shell presentation now uses the same session and ordered transcript as Chat. Physical iPad validation of the new shell presentation is still pending.

## Verification

- `swift test --package-path NativeHarness`: 60 tests passed, including presentation durability and recovery tests.
- `Tests/NativeChatChecks.swift`: deterministic transcript folding/replay checks, plus optional live host checks for Qwen reasoning, file read, tool results, allow/reject, cancellation and replay.
- Compile the check with `swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift Tests/NativeChatChecks.swift -o output/native-chat/checks`.
- Run without arguments for offline checks, or with a local JSON config path containing `endpoint` and `token` for live checks. The live check executes approved test-only `printf` commands inside the test workspace and consumes one host session slot.
- Build logs and local runtime evidence are retained under ignored `output/native-chat*` paths; credentials are not committed.

Live Mac UI verification: Enter submitted a harmless `printf` request, the existing permission card appeared, Cmd+Enter allowed it, and the existing Markdown table rendered exit code 0 and `NATIVE_UI_OK`. Separate reasoning disclosures were visible with no leaked think marker. Both Mac Catalyst and unsigned generic iOS builds passed. No device installation or public push was performed.


## Shared Chat / Shell presentation (September 8)

Chat and Shell are two renderings of one session, one ordered history and one unsent draft. Switching views does not submit, execute, copy, or create anything. In Shell, Enter executes a command (or sends input to a running program), Shift+Enter inserts a newline, and Command+Enter asks the integrated agent in place. Replies, reasoning, approvals and tool results stay in the current presentation. `/view` and the header switch select the presentation explicitly.

Commands are open blocks with cwd, output and exit status in both views. Command output never requires expanding a disclosure. Shell uses full-width monospaced content, ANSI color retention and an unboxed input; Chat uses the existing touch-friendly layout. The client captures styles from SwiftTerm's interpreted cells rather than re-parsing terminal escape sequences. Provisional zero-sized SwiftUI layouts cannot resize the emulator/PTY. Terminal width is prepared before executing a command.

NativeTranscript interleaves command blocks with agent events. A model completion cannot end a shell command, and intervening PTY events cannot split an assistant text delta. Reconnect reconstructs the shared history before publishing it to SwiftUI, avoiding a render of every replayed token. Agent observation uses the existing read-only terminal_inspect/read/wait tools; it does not take over shell input.

Verification: shared-history folding/replay checks passed; 57 core tests passed; Mac Catalyst and generic iOS builds passed. Live Mac checks verified an inline `INLINE_AGENT_OK` answer without leaving Shell, the same commands/output/answer after switching to Chat, retained ANSI colors after command completion and replay, and a 20×100 PTY with readable open output. Existing process, cwd and environment persistence were also exercised.

UI output remains bounded: 256 KiB raw bytes per retained NativeClient block and up to 64 KiB rendered preview. Styled snapshots fall back to the retained plain preview if the emulator has evicted the needed lines. The host now retains the entire received event stream on disk; historical replay is paced by network completion. Paging and compaction of very long histories remain future work.

## Session recovery milestone (September 8)

The engine database is accompanied by `DATABASE.native.sqlite`, an ordered presentation journal. Back up both databases together using SQLite-aware backups or with the host stopped (including WAL files when applicable). The presentation journal uses NORMAL-synchronous WAL for low-latency per-chunk commits: process crashes retain committed output; the last presentation transactions may be lost on power failure. Execution admission and tool dispatch still use the engine's FULL-synchronous database.

Startup closes unfinished engine turns, cancels previously unclaimed requests, marks unfinished shell blocks as interrupted with an unknown exit code, and reports unfinished tool outcomes as unknown. It does not resume model work or replay terminal input. Recovery markers are idempotent. A fresh shell is created only when its session is opened. Terminal dimensions are recorded for replay. Ordinary client disconnect leaves the current host process and command running; reconnect reconstructs the resulting output.

Request identity freezes the terminal context at first admission. A retry of the same request cannot acquire a different terminal tail or run a consumed request again. The client persists an unconfirmed request ID and reconciles it against replayed user events before clearing its draft. Unconfirmed work is never automatically resubmitted.

The client saves the split tree, pane sessions/endpoints, Chat/Shell presentation, active pane, divider ratios and text drafts in local preferences. Tokens remain in Keychain. Connection loss retries with a bounded delay; background suspension cancels retries. No changes were made to the installed `/Applications` copy or to physical devices.

Verification: 60 Swift tests, deterministic shared-transcript/recovery checks, Mac Catalyst and unsigned generic iOS builds. `Tests/NativeRecoveryChecks.swift` drives an isolated real host and Home Rig Qwen: disconnect during a shell command; replay after it completes; retry the same prompt with changed terminal output; SIGKILL during simultaneous shell/model output; reopen the same store; assert completed/partial output and ANSI bytes survive, shell exit remains unknown, the side-effect marker is written once, model work stays idle, cwd is restored, and a fresh command works. A second restart verifies idempotent recovery. The live Mac client also restored a Shell/Chat split and an unsent draft after termination.

Upgrade evidence: the pre-journal development host's eight sessions and 5,293 ordered events were captured before replacing that process, then imported into its new presentation journal. The snapshot and engine backup are local ignored artifacts under `output/native-chat/`. Physical iPad recovery behavior is not yet verified.

## Interactive terminal and inline agent output (September 8)

The reported `htop` was a foreground PTY job, but keyboard focus was in the agent composer. The old mouse interrupt button did work in that session. Shell submission now releases composer focus before running; deferred editor focus cannot steal input back from a running terminal. A visible Focus terminal action restores it after writing an agent question. Ctrl+C works from the composer as well as the terminal, including the Russian keyboard layout. The explicit interrupt command resolves and signals the current foreground process group with SIGINT, so it also works with ISIG disabled; it does not kill the persistent shell. The live terminal block sizes with the pane. Terminal input disables smart quotes, smart dashes and autocorrection.

Shell displays reasoning and tool actions inline. Agent shell stdout/stderr arrive before tool completion, preserve split UTF-8, and are replaced by one readable final result with exit status. Chat retains its existing disclosures. The presentations still share one journal and session.

The accompanying HTTP 400 was a verified Home Rig context overflow: 80,847 input tokens versus 80,128 available. Terminal context had contained both raw ANSI redraw text and a base64 copy. Model-facing terminal_read/terminal_wait results and automatic attachments now omit base64, strip terminal controls, and cap plain preview text at 4 KiB. Cursor, retention-gap, timeout and whole-PTY exit semantics remain; previewTruncated distinguishes excerpt clipping from eviction. These excerpts are explicitly not VT screen snapshots. The raw observation API and presentation journal retain bytes for rendering/replay.

When serializing older sessions to the model, legacy terminal payloads are compacted without rewriting stored history or repeating consumed requests. The previously failed session successfully continued with CONTEXT_RECOVERED: the new request used 11,118 prompt tokens. This is a repair for terminal payload inflation, not general long-history compaction. A future context overflow is classified as CONTEXT_LIMIT and displayed with an actionable message, rather than just HTTP_400.

Verification: 63 core tests passed, including explicit interrupt with ISIG disabled, bounded ANSI-heavy excerpts, legacy serialization and context-error classification. NativeChatChecks verified live tool output, split UTF-8 and no duplicate final output. Live Mac UI checks covered repeated htop launches, automatic focus, q exit, Ctrl+C from terminal/composer, explicit interrupt, and a Qwen shell command whose LIVE_BEGIN was visible during an eight-second wait before LIVE_END / exit 0 / STREAM_OK. Mac Catalyst and generic unsigned iOS builds passed. Physical iPad behavior remains unverified. Development host 8769 was restarted after engine/presentation backups; the installed /Applications copy and production DSH were not replaced.

## Command block actions (September 8)

Shell now has an explicit selected command block, a compact action bar, and a context menu. Selecting a block highlights its command and output together, pauses automatic following, and scrolls it into view. Output remains expanded. The down-arrow action returns to the latest output and resumes following.

| Action | Shortcut |
| --- | --- |
| Previous / next command block | ⌘⌥↑ / ⌘⌥↓ |
| Find in selected output (last block if none selected) | ⌘F |
| Next / previous match | ⌘G / ⌘⇧G |
| Close Find and return to input | Escape |
| Copy command | ⌘⌥C |
| Copy output | ⌘⇧C |
| Copy command and output | ⌘⌥⇧C |
| Attach selected block to the question | ⌘⇧A |
| Ask the agent in Shell | ⌘Enter |

Search is literal and case-insensitive, including Unicode. It searches the retained output preview (up to 64 KiB), highlights matches, and navigates both vertically and horizontally to the current match. The display caps at 500 matches and shows `500+` when more exist. Ordinary editor selection and copy shortcuts are unchanged. Block shortcuts are intercepted before SwiftTerm can translate modified arrows into PTY input.

The bundled `Vendor/SwiftTerm` package retains upstream 1.5.1 library sources and license, with a shortcut access hook and small symbol-font/dim-style rendering patches. Terminal parsing is unchanged. The library-only manifest omits upstream's CLI products and ArgumentParser dependency. See its README for the exact upstream commit, local changes and upgrade procedure.

An attachment is a fixed snapshot of the command, directory, output and exit status. Up to four blocks can accompany a question. Each captures at most the last 4 KiB of output, 2 KiB of command and 1 KiB of directory, with a clipping notice; UTF-8/graphemes are preserved. Reattaching the same block replaces its snapshot. Preview and remove actions are available in both composers. Text and attachments survive switching Chat/Shell, session changes and client relaunch. Shell Enter still runs a command; ⌘Enter sends the question and consumes only the acknowledged attachments.

Explicit attachments replace the implicit terminal tail. The exact captured excerpts are serialized as quoted, untrusted terminal data with the request. They cannot silently acquire later PTY output on retry. History shows the plain question and an inspectable **Attached terminal context** action; the request envelope stays in the durable journal. Both presentations reconstruct the same question and sent context on replay.

Offline checks:

```sh
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/ShellBlockInteraction.swift Tests/ShellBlockChecks.swift -o output/native-chat/block-checks
output/native-chat/block-checks
xcrun swiftc -parse-as-library PocketDSH/HarnessProtocol.swift PocketDSH/HarnessAPI.swift Shared/NativeWire.swift PocketDSH/ShellBlockInteraction.swift PocketDSH/NativeChatConnection.swift Tests/NativeChatChecks.swift -o output/native-chat/terminal-fold-checks
output/native-chat/terminal-fold-checks
```

Checks cover navigation boundaries, literal Unicode search, match limits, copy content, immutable bounded snapshots, deterministic serialization, readable sent questions and duplicate/reconnect replay. Live Mac testing uses the development host on 8769; the production DSH service and installed application bundle are unchanged. iPad hardware is offline, so physical keyboard/touch behavior on iPad remains unverified.

Live Mac evidence: selecting blocks with the keyboard, Find/match navigation, all three copy modes with exact clipboard comparison, attachment preview/removal, preserved Chat/Shell drafts and context, client relaunch recovery, and a Home Rig Qwen answer identifying the selected error and exit 1. The request journal confirms `withTerminal=false`, exactly the selected snapshot and no adjacent block. A running `sleep` fixture verified block navigation and Find while the terminal owned focus, Escape returning to the terminal, and Ctrl+C ending it with exit 130. Its output contains no leaked arrow sequence, and the next recorded command exactly matches `printf 'AFTER_NAV_OK\n'`. Local evidence is in `output/native-chat/block-actions-verification.json`.

Long-output verification found and repaired a nested-scroll boundary: the active match now uses a native view anchor to reveal its rectangle through the horizontal output scroll and vertical transcript scroll. A match on line 63 was visibly highlighted within the viewport. Find receives keyboard focus after mounting; an explicit next/previous-match request also reveals a sole match again after manual scrolling.
## Shell completion and history (September 8)

The native Shell editor supports Tab command/path completion and Up/Down command history. These bindings apply at an idle editor; a running PTY program retains its own arrows and Tab.

- Tab inserts a unique match. Multiple matches open a bounded, themed list above the prompt: Up/Down select, Shift+Tab selects backward, Tab or Enter inserts, Escape closes. Enter while the menu is visible only inserts the choice; another Enter runs it. Candidates can also be tapped.
- Up/Down browse up to 500 recent shell commands in this session's retained journal, excluding agent messages. Down past the newest restores the unsent draft and caret. Multiline/wrapped input keeps normal vertical caret movement until its first/last visual line.
- Completion runs inside the actual host zsh through a private [ZLE widget](https://zsh.sourceforge.io/Doc/Release/Zsh-Line-Editor.html), using its current directory, command table, builtins, aliases, functions and PATH. Paths support `~/`, `$NAME/`, relative/absolute names and directory-only completion after `cd`. File names are quoted on insertion. This is deliberately basic command/path completion, not the full zsh completion system for command-specific flags, Git branches or arbitrary shell syntax; substitutions and explicitly literal quoted expansion prefixes are left alone.
- The draft token is data in a private per-shell request file; no `eval`, command acceptance, inference call or startup-file modification is involved. Results are capped at 100 candidates and a bounded payload. The host refuses lookups while a program owns the terminal. Ephemeral responses are not written to the transcript or agent context.
- Request IDs plus the original text/selection reject stale replies after editing, moving the caret, changing session, opening Find or changing view. A missing/old host reports completion unavailable without losing the draft.

Validation: core tests exercise a real persistent PTY, alias/cwd/environment changes, filenames with spaces, a literal command-substitution payload, result bounds, busy-shell rejection and a clean subsequent command. Editor helper checks cover Unicode caret offsets, quoting, replacement within a command, and history/draft restoration. Live Mac checks covered alias completion/execution, a three-file menu, arrow/Shift+Tab selection, Enter insertion without execution, a quoted filename executed successfully, Escape, history restoration and htop input ownership. Both Mac Catalyst and generic iOS builds were checked; this pass did not install the new build on a physical iPad.

## Inline history suggestions (September 8)

At the end of a Shell draft, a dim continuation offers a previous command. The newest matching command from the current directory wins; otherwise the newest match in this session is used. Up to 500 retained commands are searched locally, without a host lookup or a model request. The journal supplies directory metadata during normal replay, so suggestions also work after reconnecting.

The keyboard interaction follows [fish's autosuggestion convention](https://fishshell.com/docs/current/interactive.html#autosuggestions): Right accepts the whole suffix and Option+Right accepts the next word. Quoted/escaped spaces stay together. Escape dismisses the suggestion until the draft changes. It can also be clicked/tapped. These actions insert text, never execute it; native Undo reverses insertion. Enter and Cmd+Enter use only the actual draft unless the suggestion has first been accepted.

The ghost is a separate native view over the editor, not part of its text storage. Copy/select and the saved draft therefore contain only accepted text. Suggestions hide during marked-text composition, selection, mid-line editing, Tab completion, Find, inactive panes, attached agent context and live terminal input. Single-line commands up to 4096 UTF-8 bytes are eligible; multiline/control-bearing history, leading-whitespace drafts and whitespace-only tails are not suggested. The displayed suffix is clipped to the remaining line width, leaving the prompt's layout unchanged. Prefix matching is exact and case-sensitive; this is history reuse, not shell syntax correction or path validation.

**Shell input settings → History suggestions** toggles the feature; the preference persists across launches. Existing Tab completion and Up/Down history bindings remain independent.

Validation: helper checks cover directory/recency ranking, retained-history bounds, exact/Unicode prefixes, skipped multiline/control text, whitespace-only tails and partial acceptance of quoted words. Live Mac checks covered visible alignment, Right and Option+Right, native Undo, click acceptance, cursor movement, Escape, clipboard containing only `cat` while its continuation was unaccepted, disabling/re-enabling across relaunch, and Tab opening host completion while a history hint was visible. A real command fixture recorded `true` when Enter was pressed with ` && printf 'HISTORY_RUN_ONCE\\n'` still suggested. Mac Catalyst and generic iOS builds passed. A physical iPad was not updated or tested for this increment.


## Rich terminal output and eza

The live terminal, completed blocks and Find results share the current theme's ANSI palette and terminal text size. Retained cells keep palette indices separately from explicit 256-color/RGB values, along with bold, dim, italic, underline, strikethrough and reverse video. Switching themes retints semantic ANSI colors; colors explicitly supplied by a command stay intact. Output remains selectable and expanded in both Shell and Chat. The bundled Nerd Fonts symbols face supplies file icons on Mac and iOS without changing the plain text used by Copy or agent context. Both renderers select private-use glyphs explicitly and fit them to one text column. SwiftUI output clears the inherited `fontDesign` override so theme font design cannot replace the symbol face.

File conveniences live only in each Native Harness session's private zsh configuration. They use the native `eza` executable from the **host's** PATH; no Node runtime or additional model request is involved. An iPad connected to the Mac uses that Mac's eza. Install eza on a different host to get the same file commands there.

| Command | Display |
| --- | --- |
| `ls` | Colored grid with file icons, directories first |
| `ls -lah` / `ll` | Permissions, human-readable sizes, owner, date, Git status and names |
| `la` | Detailed listing including hidden files |
| `lt` | Tree limited to two levels by default |
| `lt --level=4` | Deeper tree, using eza's own options |
| `eza …` | Direct access to the complete upstream CLI |
| `command ls …` | The platform's original ls |

The interactive `ls` wrapper translates only the shared `-l`, `-a`, `-A`, `-h`, `-r`, `-d`, `-1`, `-F` subset (including clusters). Unsupported flags such as `-t`, redirection and pipes use the platform ls. `--` protects filenames beginning with a dash. Paths and arguments are forwarded as arrays, never evaluated as shell code. `HARNESS_EZA=0 ls` bypasses the wrapper; export it to disable it for the session. Without eza, `ls`, `ll` and `la` fall back to platform listings and `lt` falls back to `ls -R`. Existing user shell configuration is not edited.

Colors use `EZA_COLORS` semantic ANSI values. Override that environment variable in the session for custom file colors; `--color=never` / `--icons=never` work with the eza-based helpers. Full CLI and styling details: [eza manual](https://github.com/eza-community/eza/blob/main/man/eza.1.md), [color configuration](https://github.com/eza-community/eza/blob/main/man/eza_colors.5.md). eza remains an optional host executable; it is not redistributed inside the Apple client.

Validation (2026-09-08): all 65 Native Harness tests passed, including a real PTY check for argument preservation, injection-shaped filenames, exit codes, redirection/pipes, unsupported flags and an absent eza binary. Existing completion/history and native transcript helper checks also passed. Live Mac checks covered a Git fixture with modified/untracked/ignored paths and symlinks, tree output, BMP/supplementary icons in live and restored blocks, Ctrl+C returning exit 130 and composer focus, ANSI styles, Find highlighting and Light/Dracula switching. Find's row now reserves its intrinsic height so the transcript cannot compress it away. Generic iOS builds include the symbol font; a physical iPad was not installed or validated in this increment.
