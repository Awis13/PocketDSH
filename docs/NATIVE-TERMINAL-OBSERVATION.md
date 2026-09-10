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
