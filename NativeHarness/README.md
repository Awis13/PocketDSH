# Native Harness — headless engine preview

A headless Swift 6 agent engine with CLI and authenticated loopback host modes, integrated into Pocket DSH as an explicit alternative backend. It does not replace a running DSH server. This is an experimental implementation, **not feature parity or a production-ready host**.

The package has no external Swift package dependencies. Runtime components are Swift/Foundation, system SQLite, and macOS POSIX process APIs; Node/npm/Python are not required to run it. Xcode/Swift is required to build.

## Build and test

```sh
swift test --package-path NativeHarness --jobs 4
swift build --package-path NativeHarness -c release --jobs 4
NativeHarness/.build/release/harness --help
```

Run these commands from the parent repository directory. Only macOS has been built and exercised so far.

## Connect Pocket DSH

After building, set `HARNESS_BASE_URL`, `HARNESS_MODEL` and a private `HARNESS_HOST_TOKEN` of at least 32 bytes (plus `HARNESS_API_KEY` if required). Run:

```sh
NativeHarness/.build/release/harness --host \
  --workspace /path/to/test-workspace --store /path/to/state/sessions.sqlite
```

The default port is 8768, configurable with `HARNESS_HOST_PORT`. Select Native Harness in the client's Connection view and paste `ws://127.0.0.1:8768?token=YOUR_TOKEN`. Tokens go to Keychain. The host only listens on loopback; iPad/iPhone require a separately configured authenticated `wss://` tunnel. No automatic tunnel or background service installation is included.

The existing Pocket interface now presents one shared Shell/Chat journal, real terminal input, inline agent output, approval cards, command selection/search/context attachments, completion and history suggestions. See [the integration contract](../docs/NATIVE-CHAT-INTEGRATION.md) for recovery, current limits and live Mac verification. The sections below also retain the earlier CLI slice evidence; their test counts describe those historical checks.

## Run against your model server

Set `HARNESS_BASE_URL` to your compatible API base URL, including `/v1`, and `HARNESS_MODEL` to its model identifier. `HARNESS_API_KEY` is optional. The endpoint and key are not written to source or session history.

Create a state directory outside the workspace, then run:

```sh
NativeHarness/.build/release/harness \
  --workspace /path/to/test-workspace \
  --store /path/to/state/sessions.sqlite \
  --session first-task \
  --prompt 'Inspect the files and explain what this project does.'
```

Repeat with the same store and session ID to continue. The session is bound to its canonical workspace path. A new workspace requires a new session ID. Only one host process may own a database at once; closing the process releases the lock.

The tools are `list_files`, `read_file`, `edit_file`, and `shell`. Writes and agent shell commands require one-use approval through `--interactive`. Without an approval controller they fail closed. Add `--allow-write` to preauthorize bounded workspace edits for this launch; it never authorizes shell commands. Edits require one exact old-text match and are limited to existing UTF-8 files of at most 64 KiB. Use disposable workspaces while evaluating the engine.

For llama.cpp templates that support it, `HARNESS_DISABLE_THINKING=1` sends `chat_template_kwargs.enable_thinking=false`. This option is off by default. Do not enable it for the current Home Rig Qwen endpoint: live checks found that it can put reasoning and `</think>` into ordinary content. The default server template supplies separate `reasoning_content` and `content` streams.

Ctrl-C cooperatively cancels the foreground model request. Partial streamed text is provisional and is not a committed final answer. EOF without the expected stream terminator, invalid tool responses, and output-limit termination fail explicitly.

## Implemented

- Session driver with bounded model/tool steps per turn, durable queue/steering, and overlapping-run rejection.
- Compatible HTTP/SSE streaming, text and reasoning callbacks, indexed tool argument assembly.
- SQLite event history with FULL synchronous mode, transactional appends, and a host writer lock.
- Tool-start persistence before invocation; interrupted calls recover as not-started or outcome-unknown.
- Read-only defaults, workspace path checks, bounded file reads and exact-match edits.
- Transactional command receipts, pending-command removal, and claim-to-history admission.
- CLI, automated protocol/engine tests, real Home Rig edit-and-verify and process-restart checks.

## Queue, steering, and restart

`SessionEngine.enqueue(prompt:mode:commandID:)` commits an inbox entry and returns a receipt. `SessionDriver.submit` adds the host wake policy: it drains pending commands automatically, including commands arriving while a previous drain is settling. A queue entry begins a separate turn. Steering is collected at the next model-step boundary, after the current request and its tools settle; it does not change an already transmitted model request.

If steering arrives while an answer is finishing, the final steering check and turn closure are serialized in SQLite. A committed steering entry before closure extends that turn. An entry committed after closure starts subsequent work. At a fresh turn, the oldest queued prompt is followed by all pending steering; with no queued prompt, pending steering can start a turn on its own.

Receipt states are `pending`, `consumed` (admitted to history, **not necessarily completed**), and `cancelled` (removed before claim). Reusing the same ID and payload/mode returns its current receipt and does not create another message. Changing payload or delivery mode under that ID is rejected. IDs are scoped to a session. The receipt table is retained, including removed commands. Pending entries are limited to 256, prompts to 256 KiB, and command IDs to 128 UTF-8 bytes.

Claiming commands, recording their user messages, and starting the turn are one transaction. SQLite write failure rolls all of these back. After a hard kill, unclaimed messages remain pending. Claimed work remains in history and its interrupted turn is repaired; it is not blindly replayed. To continue that interrupted task, submit a new instruction. Use `--resume` without `--prompt` to drain only pending work:

```sh
NativeHarness/.build/release/harness \
  --workspace /path/to/test-workspace --store /path/to/state/sessions.sqlite \
  --session first-task --resume
```

Cancellation stops execution and **preserves unclaimed messages**. Failures pause the host driver; it does not automatically run the remaining queue after a failed turn. Resume is explicit; submitting pending work through `SessionDriver` also wakes it. `removePending(commandID:)` only removes a still-pending entry. The existing direct `run(prompt:)` remains a convenience that admits a new prompt with a fresh ID and drains work; it returns the last completed answer in that drain. For retry-safe submission use explicit command IDs with the inbox/driver API.

### Local interactive control

Start with `--interactive`, optionally with an initial `--prompt`. Send one JSON object per stdin line while output streams:

```json
{"op":"queue","id":"task-2","prompt":"Inspect the next file after this task."}
{"op":"steer","id":"clarification-1","prompt":"For the current task, preserve the public API."}
{"op":"pending"}
{"op":"remove","id":"task-2"}
{"op":"status"}
{"op":"cancel"}
{"op":"resume"}
```

Control replies and diagnostic stages go to stderr; response text goes to stdout with a separator at turn completion. Interactive Ctrl-C stops the driver while keeping the control channel open. EOF waits for the active drain to settle. Interactive startup does not automatically resume old pending messages unless `--resume` or a new submission is supplied. This is a local stdin channel, not a remote authenticated protocol. In-process clients should use `SessionDriver`; bare `enqueue` persists only and requires `runPending` or a host wake.

To reproduce process death and recovery with a deterministic local provider:

```sh
python3 scripts/probe-native-inbox.py --binary NativeHarness/.build/release/harness
```

The probe kills the CLI while its first request is pending, preserves a queued prompt and steering message, restarts against the same database, and checks exactly one history admission for each command. An additional empty resume must not replay consumed work. This is a process-crash test, not a power-loss guarantee.

## Shell blocks and one-use approvals

In `--interactive` mode, stderr emits an `approval` JSON event containing a generated request ID, the exact tool call and workspace. Answer through stdin:

```json
{"op":"approval","id":"REQUEST_ID","allow":true}
```

Use `false` to deny. A decision is consumed once, never grants future commands, and late answers after cancellation are rejected (`removed: false`). The journal records requested/allowed/denied/cancelled decisions before effects. Closing stdin denies pending/future approvals and cancels a human shell command; an already approved agent command continues until its turn ends or is cancelled. Ctrl-C cancels both the current agent turn and human command. File contents are checked again after approval before editing. `--allow-write` remains an explicit per-launch exception for edits only.

The local control channel also supports human commands and selected context attachments:

```json
{"op":"shell","command":"git status --short"}
{"op":"shell-cancel"}
{"op":"blocks"}
{"op":"context","blockID":"BLOCK_ID"}
{"op":"send-context","blockID":"BLOCK_ID","id":"question-1","prompt":"Explain this result"}
```

`context` previews the same attachment that `send-context` queues for the agent. Each output stream is shortened to 8 KiB in the attachment; the full bounded command block remains in the journal. Output is labeled untrusted data. This is not automatic secret detection: inspect the preview before sharing sensitive command output. A human command alone makes **no model request** and adds no model message. Commands and context target the selected workspace/session. Completed blocks survive restart; interrupted blocks are not presented as completed. A human shell submission is an explicit execution request, without a second approval dialog; it has no retry/idempotency receipt and must not be automatically resent.

`WorkspaceTools` has one execution slot shared by human and agent commands, including an agent waiting for approval. A second shell command is rejected as busy. Commands use fresh `/bin/zsh -f -c` processes with stdin attached to `/dev/null`; `cd` and shell variables do not persist between commands. Environment inheritance is limited to a fixed system PATH, HOME and LANG, excluding the harness API key. Commands still run with the host user's permissions and can access paths outside the workspace: the workspace is a working directory, **not a sandbox**.

`ShellRunner` streams separate stdout/stderr byte events while a command runs. CLI `shellOutput` events encode bytes as base64; consumers should use a streaming decoder for split UTF-8 and escape terminal control characters when displaying untrusted output. Completed blocks contain command, workspace, timestamps, output, exit code or terminating signal, and outcome. The default limits are 30 seconds and 64 KiB combined output; overflow terminates the command and reports `outputLimit`. Timeout/cancellation sends SIGTERM to the process group, then SIGKILL after a short grace period. The leader PID stays reserved until group cleanup, preventing accidental signaling of a reused PID. Descendants deliberately escaping that group are not contained. Killing the host with SIGKILL can leave commands running; journal recovery never blindly replays them.

These are engine and CLI control APIs. Enter for shell / Cmd+Enter for agent / Shift+Enter for newline is the intended future UI mapping, not a keyboard binding installed in Pocket DSH by this slice. A real PTY and interactive programs such as vim remain future work.

Reproduce real process/control checks without a model server:

```sh
python3 scripts/probe-native-shell.py --binary NativeHarness/.build/release/harness
```

This exercises allow, deny, controller disconnect, running-command cancellation, incremental output and explicit human-block handoff against a loopback model fixture. It executes only disposable commands in temporary workspaces.

## Persistent interactive terminal (macOS)

```sh
NativeHarness/.build/release/harness --terminal --workspace /path/to/project
```

This opens a real PTY and persistent `/bin/zsh -f -i` inside the terminal you are already using. No model configuration is required for this command. `cd`, exported variables, line editing and shell job control persist. Enter and ordinary terminal keys go to the shell; Ctrl-C interrupts the foreground program and keeps the shell available. `exit` leaves the session and returns its exit code. The host forwards window-size changes and restores the caller's terminal attributes on normal exit and handled SIGTERM. SIGKILL cannot run cleanup.

The existing terminal application renders ANSI/VT sequences, including full-screen programs; the Swift core does not pretend raw escape sequences are chat text. The environment includes a fixed system PATH, HOME, LANG and TERM, not the model API key. `-f` deliberately skips user zsh startup configuration; loading the user's full shell configuration is not a setting yet. The small in-tree C bridge wraps system PTY APIs and performs the post-fork exec path without returning into Swift/Foundation. It adds no package or runtime dependency; it uses macOS libc.

`PTYSession` exposes byte input/output, resize, interrupt, close and an exit result. Input is bounded to 64 KiB pending bytes and rejected on overflow; output callbacks run synchronously and must stay short. Output merges stdout/stderr, includes terminal echo and control sequences, and is not automatically journaled or submitted to the model. The existing finite `shell` tool and completed `CommandBlock` context remain separate. An agent cannot inject keystrokes into this user-owned PTY through its tool catalog.

For local developer control through `--interactive`:

```json
{"op":"pty-open","rows":30,"columns":100}
{"op":"pty-input","ptyID":"PTY_ID","bytes":"cHdkDQ=="}
{"op":"pty-resize","ptyID":"PTY_ID","rows":42,"columns":120}
{"op":"pty-interrupt","ptyID":"PTY_ID"}
{"op":"pty-close","ptyID":"PTY_ID"}
```

The input example encodes `pwd` plus Return. `ptyOpened`, `ptyOutput` and `ptyExited` events identify the session with a generated `ptyID`; output bytes are base64. Output can arrive immediately, so consumers must route by ID rather than rely on the order of open acknowledgments. Old IDs are rejected after close/reopen. One PTY can be open per CLI controller; stdin EOF closes it. In JSON control mode, `pty-interrupt` is deliberately separate from cancellation of an agent turn. This mixed stderr developer protocol is not an authenticated application or network transport.

Close sends hangup to the current foreground group and the shell group, with bounded escalation for the shell group. This handles ordinary interactive jobs; descendants deliberately escaping/ignoring session shutdown are not sandbox-contained. PTY sessions are ephemeral and are not restarted or replayed from history after a crash.

Pocket DSH now offers this engine alongside the existing DSH HTTP/WebSocket backend. Its UIKit/Mac Catalyst editor and SwiftTerm surface send shell input separately from Cmd+Enter agent requests, preserving a common transcript. iPad runs the client view; shell execution remains on the Mac host. Physical iPad validation of the new native shell is pending.

Verification:

```sh
python3 scripts/probe-native-pty.py --binary NativeHarness/.build/release/harness
```

The probe opens an actual outer PTY, verifies usable `/dev/tty`, persistent cwd/environment, initial and updated size, Ctrl-C followed by another command, entry/exit of system vim, exit-code propagation and restoration of terminal settings. A second probe exercises JSON control, resize, stale IDs, EOF cleanup and API-key exclusion. Swift tests cover Unicode byte fragments, queue bounds, close during output and shell lifetime. On macOS, `PENDIN` is a transient kernel state flag after returning to canonical input and is excluded from the settings comparison.

## Agent observation of a running PTY

In `--interactive` mode, the agent now has three read-only tools: `terminal_inspect`, `terminal_read`, and `terminal_wait`. These are the wire names for the conceptual `terminal.inspect/read/wait` APIs. Start a PTY through `pty-open`, run a command yourself, then queue a request asking the agent to observe it. The agent can join after execution has begun; it does not need to own or restart the command.

Capture is synchronous with each PTY output callback and preserves byte order independently of model requests. Each terminal retains up to 1 MiB of raw output in memory. The catalog retains up to eight terminals and evicts the oldest completed terminal when necessary; it never evicts an active one to admit another. Unknown/evicted terminal IDs return an error. This history lasts for the host process lifetime, not across host restart. Portions read by the model are also part of normal tool-result conversation history; this is not a complete durable terminal log.

`terminal_inspect` returns IDs, **initial** workspace, retained cursor range, waiter count and whole-PTY exit state. It does not know the current cwd inside SSH, foreground command, rendered screen, or individual command exit status. A live PTY can contain an idle shell, a running command or an input prompt. Silence and timeout do not distinguish those states.

`terminal_read` takes string arguments `terminal_id`, `after` (initially `"0"`), and optional `max_bytes` (default `"16384"`, maximum `"65536"`). The result includes:

- `startCursor`, `nextCursor`, `latestCursor`: monotonically increasing byte offsets scoped to that terminal ID; pass `nextCursor` to resume without skipping unread pages.
- `gap`: older requested bytes were evicted; `startCursor` identifies the earliest returned position.
- `bytes`: canonical base64 bytes, including terminal controls; `text`: lossy UTF-8 preview for the model, which may replace fragments split across reads.
- `exit`: the **entire PTY** exited; `timedOut`: an observation wait reached its deadline.

Terminal output is untrusted data. Echoed input can contain text that a command has not actually printed yet; do not treat a matching word alone as proof of completion. A future shell integration will provide trustworthy command boundaries and a separate screen representation.

`terminal_wait` accepts the same read arguments plus `timeout_seconds` (default `"30"`, >0 and <=60). It returns immediately for unread bytes or a known exit; otherwise it registers an event-driven waiter. Capture and wait registration share a lock, preventing output between read and wait from being missed. Timeout and task cancellation unregister the waiter. Cancelling an agent turn leaves the user's PTY running. Up to 32 waits can be pending per terminal. The existing agent step limit still applies; this is not yet a persistent autonomous monitoring service or semantic progress coalescer.

Local diagnostic controls can inspect/read the same history without invoking a model:

```json
{"op":"pty-inspect"}
{"op":"pty-read","ptyID":"PTY_ID","after":0,"maxBytes":16384}
```

Responses use `ptyInspection` / `ptyRead`. Raw `ptyOutput` notifications remain available for the live terminal renderer; observation cursors provide the catch-up path. Input ownership has not changed: no `terminal_send` or `terminal_interrupt` model tools are exposed.

The accepted broader design and outstanding boundaries are recorded in [terminal observation design](../docs/NATIVE-TERMINAL-OBSERVATION.md).

```sh
python3 scripts/probe-native-observation.py --binary NativeHarness/.build/release/harness
```

This real CLI/PTY probe starts a process before the agent request, verifies `terminal_inspect → terminal_read → terminal_wait`, emits later output, and checks that the local control channel remains responsive during the wait. The model transport is a deterministic local fixture. A separate live Home Rig Qwen run exercised the same tools, observed `LIVE_LATE` after joining, then correctly reported whole-PTY exit code 0. No real system upgrade was performed. The complete Swift suite passed 54 tests, including cursor gaps, paging, cancellation, timeout, retention, byte fragments and wait-registration races. Existing PTY, shell/approval and inbox-crash probes also passed.

## Execution diagnostics

The CLI now prints stage changes to stderr immediately, independently of response text on stdout. `accepted` means the in-process run was admitted; `ready` follows persistence of the initial turn and prompt. Neither is a remote idempotent command receipt. `requesting`, response headers, first SSE data, first reasoning/text, tool execution, persistence, and the terminal outcome have separate events. Available reasoning is shown only with `--show-reasoning`.

Add `--trace /path/to/new-trace.json` to export a diagnostic snapshot. The path must not already exist. From another terminal, while execution is in progress or after it ends:

```sh
NativeHarness/.build/release/harness --inspect-trace /path/to/new-trace.json
```

Inspection needs neither provider configuration nor database ownership. It returns the last published snapshot, not a guarantee that the recorded process is still alive; check its timestamp. A hard kill may leave the last in-progress stage. Session recovery remains the responsibility of the SQLite journal.

The report includes engine/OS versions, process ID, monotonic elapsed times, per-request milestone timings, and session/turn/step/request/tool correlation IDs. Session references are SHA-256 hashes of caller session IDs; other IDs are generated UUIDs. Durable events carry matching trace IDs for local correlation. The report excludes prompts, reasoning, responses, file paths/content, tool arguments, endpoints, keys, and raw error descriptions. The SQLite conversation journal still contains conversation/tool content and must be treated separately.

The in-memory trace and exported file retain at most 256 events and report how many older events were dropped. Token chunks are not logged: only their first observable milestones are retained. Missing timing fields mean not observed, not zero. Timing summaries require the corresponding request-start event to remain in the retained window. Response-header/data times include transport and provider-side waiting; this adapter cannot split server queue time from prompt processing or measure cache hits. No guessed progress percentages are emitted.

For programmatic control, `await engine.diagnostics()` returns a current bounded snapshot; `await engine.cancel()` requests cooperative cancellation. Caller task cancellation is also forwarded. These are in-process APIs, not an authenticated remote control server. Diagnostic observers are synchronous and should remain short; custom observers should enqueue UI work rather than blocking the model stream. Trace-file write failures warn on stderr but do not veto execution.

### Reproduce transport failures

```sh
python3 scripts/probe-native-harness.py --binary NativeHarness/.build/release/harness
```

This development-only probe starts a temporary loopback HTTP server and exercises HTTP 503, a truncated SSE response, and Ctrl-C during a pending response. It checks exit status, final diagnostic classification, and persisted turn closure. No real model or project is used. Python is a development helper, not a runtime dependency of the engine. The deterministic Swift tests also cover first-event reporting, bounded retention, redaction, request IDs, overlapping session owners, and cancellation through the engine API.

## Not implemented yet

General shell integration beyond the private zsh configuration; OS sandboxing and containment of descendants that escape their process group; parallel tools; balanced context compaction; provider retries and usage accounting; model/effort selection in the client; image/voice content; goal/subagent/workflow/skill drivers; agent PTY writes and takeover; client queue editing and steering; automatic secure remote access and background service packaging. Inbox receipts are durable, but receipt/history retention quotas and paging are not implemented. The authenticated loopback host, client rendering, command boundaries and restart journal are implemented; they must not be confused with a hardened remote service or process resurrection.

Workspace path checks are not an OS sandbox and do not protect against hostile concurrent symlink replacement or all filesystem races. SQLite recovery checks do not establish power-loss or disk-full reliability. History is loaded in memory without paging/compaction. Do not use this slice as an unattended privileged agent.

## Development evidence

On 2026-09-08, Home Rig's `qwen3.8-27b` generated the initial SSE decoder and six parser tests. The first generation exhausted its response budget; a second request with thinking disabled produced complete code. Additional local tests exposed three defects (standalone CR, colonless data fields, and stale event state after EOF), which were corrected before integration.

The same model then ran through this Swift executable: read a fixture, edit its greeting, read it back, and return the actual changed value. A second process reopened the stored session and recalled that value. Local raw requests/responses, timings, test logs, and fixture history are retained under the gitignored `output/native-harness/` directory. No user project files were edited by those live checks.

In the diagnostics slice, Home Rig also generated five trace unit tests. An independent subprocess cancellation probe exposed an inherited MainActor isolation trap in the CLI signal callback; the callback was made explicitly Sendable and the transport probes were repeated. A live read-file turn produced observable request and tool milestones. This is evidence of instrumentation and cancellation behavior, not a claim that inference has been accelerated.

The research and broader target remain in [architecture research](../docs/NATIVE-HARNESS-RESEARCH.md) and [acceptance scenarios](../docs/NATIVE-HARNESS-SCENARIOS.md). This slice exercises only a subset of that target; it does not mark the full scenario list complete.

The shell/approval slice was checked with 44 passing Swift tests, five real CLI/process scenarios, and the existing transport and inbox crash probes. Home Rig supplied an initial shell test draft; unused scripts and an unsupported environment assumption were removed before integration. A live Qwen turn then requested one exact read-only shell command, received one-use approval, and reported its actual stdout and exit status. Request/response and execution evidence remain under the gitignored `output/native-harness/` directory. No Pocket DSH UI or production server deployment is included in this slice.

For the PTY slice, Home Rig was also queried for additional terminal checks. Its two suggested snippets were rejected: one incorrectly expected `tty` to return `/dev/tty`, and neither tested the claimed condition correctly. Actual verification uses the local Darwin contract and real PTY subprocess probes.
