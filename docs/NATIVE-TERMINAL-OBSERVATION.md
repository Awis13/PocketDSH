# Agent observation of a live terminal

Accepted on 2026-09-08. The motivating scenario is a user starting a Linux upgrade and asking the agent to watch it while it continues. The process must not be restarted or transferred to a different shell just so the agent can see it.

## Agreed behavior

- Collect output independently of model requests. Joining midway must expose retained output and subsequent bytes.
- Use explicit terminal IDs and ordered cursors. Reconnecting observers resume from their cursor; missing retained data is reported as a gap, never silently skipped.
- Offer `terminal.inspect`, `terminal.read`, and cancellable `terminal.wait`. Waiting is event driven and does not repeatedly query the model.
- Keep raw output available within declared retention limits. Summaries/progress coalescing are a separate model-facing projection.
- Distinguish an idle shell, a running foreground command, the exit of that command, and the exit of the entire PTY. Do not infer these states from silence or a prompt-shaped line.
- Inspection should ultimately expose host, current cwd, foreground process and a rendered screen alongside scrollback. An initial cwd and raw bytes are not a current screen snapshot.
- Read-only observation and control are distinct capabilities. `terminal.send`/`terminal.interrupt` require explicit authority. Human input revokes agent control; concurrent competing keystrokes are prohibited.
- An agent watching an upgrade should wake on meaningful output, questions, errors, completion or an explicit timeout. Repeated progress counters must not fill the context or cause a model request for each chunk.

## First implementation boundary

A per-PTY bounded in-memory output history, byte cursors, read/inspect/wait APIs and read-only model tools. Timeout/cancellation must unregister waiters. Data arriving between inspection and wait registration must not be lost. All consumers see the same output ordering. Completed PTY observations remain readable within the same host lifetime.

This does not yet implement persistent disk scrollback, screen emulation, shell command boundaries, automatic upgrade-error classification, remote Linux process inspection or agent keyboard control. These are tracked separately in the Native Harness Obsidian kanban. Existing manual PTY controls and explicit command-block attachments remain available.

## Acceptance evidence required

Join after a command has started, read already-emitted bytes, await delayed output without polling the model, resume without duplicates, observe PTY exit, report history eviction, cancel/timeout without leaked waiters, and keep terminal input responsive while a model tool is waiting. Verify with a real delayed shell process and a model on Home Rig; no real system upgrade is required for the test.

## Implemented evidence (2026-09-08)

The first boundary is implemented locally in `TerminalObservation.swift`, `PTYSession.swift`, `WorkspaceTools.swift` and the CLI control layer. Retention is in memory (1 MiB/terminal, eight catalog entries); model tools are read-only. 54 Swift tests passed; the real CLI fixture and live Home Rig Qwen both joined a running PTY and observed later output. User keyboard control remained separate and responsive. Remaining agreed features above are still planned, not implied by this result.

## Model-visible command lifecycle (2026-09-11)

`TerminalObservation` now keeps a bounded ring of command records (64 per terminal, command and directory clamped to 4 KiB each) built from the private nonce-DCS `preexec`/`precmd` frames. Each record carries `seq`, `command`, `directory`, `exitCode` and `startedAt`/`endedAt`; an open record has no end, and the initial prompt is stored as a standalone record with no command. `terminal_commands` returns the newest records as bounded JSON (default 32, max 64) through `TerminalModelContext`, which strips terminal controls and labels the payload untrusted data. `terminal_inspect`, `terminal_read` and `terminal_wait` keep their existing fields and add the additive lifecycle/foreground fields described below; no agent keyboard/write tool is added.

Command boundaries are display lifecycle, not execution authority. A record only proves the shell reported a start and later a prompt with an exit status; it does not prove the command was helpful, that its output was captured, or that the process tree ended.

## Wait conditions and wake policy (2026-09-11)

`terminal_wait` takes a `condition`:

- `bytes` (default) — the original behavior: new raw output after the cursor, or retention gap.
- `command_finished` — a new `precmd` that closes an open `preexec`. The result carries the command record (command, cwd, exit code, timestamps). Output alone never satisfies it.
- `cwd_changed` — the shell reported a different directory than the one the waiter observed at registration.

Command pairing is tail-only: a `precmd` closes the most recent open `preexec`, and a new `preexec` that arrives while the tail is still open closes the superseded record (with no exit code) instead of leaving it open to steal a later prompt. The observation is seeded with the canonical workspace path (`realpath(3)`, which also resolves macOS firmlinks) that the PTY also chdirs to, so the first prompt never looks like a spontaneous `cwd_changed`.

The result keeps every existing field and adds `condition`, `command` and `cwd`, so older clients that read `text`/`nextCursor` are unaffected. Every wait still ends on the same terminal outcomes: the requested condition, a timeout, whole-PTY exit, or caller cancellation; a retention gap ends a `bytes` wait only and never wakes a lifecycle wait.

**The wait is the wake.** A model request resumes only when one of those outcomes occurs; there is no hidden idle-agent auto-wake and no background model polling. `bytes` is not evidence a command finished, a timeout is not evidence a command finished, and a single command exit is not a whole-PTY exit. `foreground_idle` is deliberately not a condition.

The real CLI probe `scripts/probe-native-observation.py` covers a blocking `command_finished` wait, a `cwd_changed` wait, and the `terminal_commands` list on an isolated fixture host.

## Foreground state (2026-09-11)

`terminal_inspect` now reports `foregroundPgid` (the `tcgetpgrp` of the PTY master, resolved live on each inspection) and `foregroundBusy` (true when the foreground group differs from the shell's own group). The observation resolves the foreground group through the provider attached to the owning PTY, never cached for a later signal.

macOS has no supported query for "is a process waiting on stdin", so exact stdin-waiting is not reported: DSH hardcodes that signal false and states only the foreground process group. This is not proof that a command is interactive, backgrounded, or complete.

`foregroundBusy` is `null` when the group is unknown or unavailable — an unknown group is never reported as idle or busy. It is `false` only when a known foreground group matches the shell's own group, and `true` only when a known foreground group differs. Immediately after `forkpty` returns, and before the child establishes its session and controlling terminal, the PTY has no foreground group and `foregroundPgid` is nil; it settles once the shell owns the terminal. Readers should treat nil as "unknown", not "idle".

## Interactive PTY startup (2026-09-11)

`PTYControl` now constructs its session with `segmented: true`. The delta from the previous startup is concrete:

- argv changes from `/bin/zsh -f -i` to `/bin/zsh -d -i`.
- The environment gains a private generated `ZDOTDIR`, plus `PROMPT`, `RPROMPT` and `EZA_COLORS`, and the `ls`/`ll`/`la`/`lt` interactive overrides, all injected from `ShellIntegration`.

The flag is required: without `ShellIntegration` there are no `preexec`/`precmd` lifecycle markers, so `terminal_commands` and the `command_finished`/`cwd_changed` wait conditions are inert on that path. `PTYControl` is used only by `--interactive` (the developer control channel); the shipped application path (`NativeHost`) already constructed its session with `segmented: true` before this change. `-d` skips global rc files, and the private `ZDOTDIR` means the user shell configuration is never edited.

This is a host-side startup change only. The model tool schema, the JSON field names and the local control protocol are unchanged.
