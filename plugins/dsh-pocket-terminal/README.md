# dsh-pocket-terminal

Server-side PTY session core for PocketDSH's real terminal on the DSH leg
(**commit C1** of ticket DSH-TERMINAL). A PocketDSH session gets a real
interactive shell in a PTY: Enter runs `ls`/`htop` in the terminal, and the
terminal respects the session's sandbox policy.

This commit ships the **server-side core only** (no transport, no UI, no
profile wiring — those are C2–C4). It is structured so the core is testable
with an injectable fake PTY (no real `spawn`), and the cordis binding is a
thin seam over it.

## Layout

| File | Role |
| --- | --- |
| `core.js` | Pure, dependency-free core: `TerminalManager` + `installSandboxModeFence`. No `node-pty`/cordis imports — the PTY is injected. |
| `index.js` | Cordis binding: exports `name`/`inject`/`apply`, the `toRawPty` resize adapter, and the `createManager` factory. Provides the `pocketTerminal` service for C2. |
| `test/pocket-terminal.test.js` | `node --test` suite over the core with a fake PTY. |
| `package.json` | No external deps (matches `dsh-voice`). |
| `cordis.patch.yml` | Bundle patch (plugin record), same shape as `dsh-voice`/`dsh-images`. |

## How it works

A `TerminalManager` is bound to **one session** and owns **one PTY** and **one
input writer**:

- `spawn({cwd?})` resolves the session's sandbox policy
  (`ctx.sandboxPolicy.resolve({session})`), confines the shell `argv`
  (see *Sandbox confinement* below), and spawns through the injected
  `spawnTerminal(spec)`. It **freezes the sandbox mode** and installs the
  mode fence **before** any `await`, so a mode change during the async spawn
  is already blocked.
- `write(data)` / `signal(sig)` require the input writer and forward to the
  PTY. `resize(cols, rows)` forwards to the PTY's `resize` (the TIOCSWINSZ
  path — see *Resize*).
- PTY output is streamed to `onData` observers. When the process exits, the
  manager settles: it removes the session from the live set (fence inactive),
  releases the writer, disposes the PTY (`terminate()`, TERM→KILL), and
  notifies `onExit` observers with the outcome.

### Raw PTY contract

The core consumes an injected raw PTY (produced by the cordis adapter or a
test fake):

```ts
{
  pid: number,
  output: AsyncIterable<Buffer | string>,      // UTF-8, ends on exit
  done: Promise<{ exitCode: number | null, signal: string | null }>,
  write(data): Promise<void>,
  signal(sig): Promise<number>,                 // SIGINT|SIGTERM|SIGKILL|SIGTSTP|SIGHUP
  resize(cols, rows): void,                     // TIOCSWINSZ
  terminate(): Promise<void>,                   // TERM -> graceMs -> KILL
}
```

### Resize (TIOCSWINSZ)

The seam's `SubprocessTerminalHandle` (`ctx.subprocess.spawnTerminal`) has **no
resize of its own** — node-pty's `IPty.resize(cols, rows)` is not exposed. The
`toRawPty` adapter in `index.js` recovers the node-pty handle from the seam
(LocalTerminalHandle stores it on a JS-private `this.terminal` field) and calls
`IPty.resize(cols, rows)`, which on Unix is the TIOCSWINSZ ioctl
(`pty.resize(fd, cols, rows)` in node-pty's native). The core's own `resize`
takes `cols` first, then `rows` (matching node-pty).

## Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `rows` / `cols` | `24` / `80` | Initial PTY geometry (TIOCSWINSZ at spawn). C2 sets the real size from the client and drives `resize` on terminal resize. |
| `graceMs` | `5000` | TERM→KILL cleanup grace for the PTY's full lifetime (passed to the seam; the seam sends SIGTERM then SIGKILL after this window). |
| `shellArgv` | `["/bin/bash","-l"]` | The login shell argv. Confined per the session policy before spawn. |
| `term` | `"xterm-256color"` | `TERM` in the child env. A real `TERM` (not `dumb`) is required so alt-screen apps (htop, vim) work. |
| `baseEnv` | `{}` | Extra child env vars (merged in). The core always adds `TERM`, `DSH_SHELL=1`, `DSH_SESSION_ID`, `DSH_PTY_SESSION_ID`. |
| `cwd` | policy `workspaceRoot` | Working directory for the shell (overridable per spawn). |

### Sandbox confinement

The shell `argv` is confined per the session's resolved mode (same shape as the
sample `dsh-terminal-bash` `spawnArgv`):

- `danger-full-access` → the `argv` is passed through **unwrapped**.
- `read-only` / `workspace-write` → the `argv` is wrapped by
  `ctx.sandbox.confine(argv, policy).argv`.

If a confined mode is resolved but no `sandbox` provider is available, spawn
throws (a confined shell must actually be confined).

### Sandbox-mode fence ("mode does not change while a PTY is live")

The upstream `ensureSandboxModeFence` is not exported, so this plugin carries its
own (`installSandboxModeFence`). A session's mode must not change while a PTY is
live or being created: the PTY spawned confined to the **frozen** mode, so a
mid-life switch would silently re-scope the shell the user is typing into.

The fence is a global `internal/dispatch` observer for the session. Because
`session.append` is synchronous and rejects before the log changes when a
`internal/dispatch` observer throws, a disallowed mode change (i.e. one that
`setSandboxMode` would log) is **rolled back** and never lands. The frozen mode
is the policy in effect at spawn time. A no-op re-set of the frozen mode, and any
change while no PTY is live (before spawn / after exit), are allowed.

## Tests

```sh
node --test plugins/dsh-pocket-terminal/test/*.test.js
```

Covers: confinement by all three modes, write/read forwarding, resize
forwarding (cols,rows), signal forwarding, process exit + cleanup + mode
unfreeze, abnormal exit, second-writer rejection, and the mode-change fence
(blocked-while-live / no-op-allowed / inert-before-spawn / inert-after-exit,
plus the standalone fence helper). All PTYs are fakes — no real `spawn`.

## Threat model

- **A live shell outlives a policy change.** The shell runs at whatever mode it
  spawned with. The fence freezes that mode for the PTY's lifetime and rejects
  (rolls back) any conflicting `sandbox/mode` change while the PTY is live.
  Closing the terminal (or the process exiting) unfreezes the mode.
- **Two clients typing at once.** Only one input writer is allowed; a second
  `acquireWriter` is rejected so keystrokes never interleave. Watchers read via
  `onData` and never write.
- **Terminal output leaking into logs.** The core forwards output to `onData`
  observers and never logs it; the seam's `output` is consumed, not printed.
  (C2 streams it only to the attached client and keeps cookies/terminal bytes
  out of logs.)
- **A confined shell escaping its scope.** Enforced by the sandbox provider via
  `ctx.sandbox.confine`; the core trusts the confined `argv` it is handed and
  passes the geometry/env through. The core never widens the scope — a confined
  mode with no provider is a hard error, not a silent passthrough.
- **No escalation from the terminal.** The shell runs at the frozen mode; the
  PTY cannot itself request a higher mode. Escalation still goes through the
  normal policy path (and is blocked while the PTY is live).
- **Child environment.** The child env is minimal by default (`TERM`,
  `DSH_SHELL`, session ids); C2 can add vars via `baseEnv` but the core does
  not copy the host env into the shell.
- **Resize.** `TIOCSWINSZ` only sets the window size; the child app adapts.
  There is no privilege change, only the size the app allocates for itself.

## Out of scope (C2–C4)

`pocketTerminal/attach` stream method + transport, reconnect-in-grace, real
node-pty spawn + live TIOCSWINSZ verification, profile wiring
(`dsh --profile web --dump-config`), and the native Catalyst terminal surface.
