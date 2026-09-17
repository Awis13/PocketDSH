// Pocket DSH — server-side PTY session core (commit C1 of DSH-TERMINAL).
//
// Pure, dependency-free core. A TerminalManager bound to one session owns a
// single PTY, a single input writer, and the "sandbox mode is frozen while a
// PTY is live" fence. No node-pty / cordis imports here: the PTY is injected
// through spawnTerminal(spec), so the core is fully testable with a fake PTY.
// The cordis binding (index.js) supplies the real ctx.subprocess.spawnTerminal
// and the resize adapter that reaches the node-pty handle (TIOCSWINSZ).

// The three sandbox modes, in escalation order (read-only is least privileged).
export const SANDBOX_MODES = Object.freeze(["read-only", "workspace-write", "danger-full-access"]);

// ---------------------------------------------------------------------------
// Sandbox-mode fence.
//
// The upstream ensureSandboxModeFence (dsh-terminal-bash) is not exported, so
// this plugin carries its own. A session's sandbox mode must not change while a
// PTY is live: the PTY spawned confined to the frozen mode, so a mid-life mode
// switch would silently re-scope the shell the user is typing into.
//
// session.append is synchronous and rejects before the log changes when an
// internal/dispatch observer throws, so a disallowed mode change is rolled back
// and never lands in the session log. We freeze the mode at spawn time
// (deterministic, independent of projection-fold timing).
//
//   ctx     — the cordis context (emitter), or null for a headless core.
//   session — the session this fence protects.
//   isLive  — () => boolean; true while a PTY is live or being created.
//   frozenMode — () => string|null; the mode in effect at spawn time.
//
// Returns a disposer.
// ---------------------------------------------------------------------------
export function installSandboxModeFence(ctx, { session, isLive, frozenMode } = {}) {
  const on = ctx && typeof ctx.on === "function" ? ctx.on.bind(ctx) : undefined;
  if (typeof on !== "function") return () => {};
  const handler = (_mode, eventName, args) => {
    if (eventName !== "session/event") return;
    const [eventSession, event] = Array.isArray(args) ? args : [];
    if (eventSession !== session || !event || event.type !== "sandbox/mode") return;
    if (!isLive()) return; // no live PTY — the mode is free to change
    const wanted = event.data && event.data.mode;
    const frozen = frozenMode();
    if (frozen !== null && frozen !== undefined && wanted === frozen) return; // no-op re-set of the frozen mode
    throw new Error(
      "pocket-terminal: cannot change sandbox mode to " + JSON.stringify(wanted) +
      (frozen ? " while a terminal is live (frozen at " + JSON.stringify(frozen) + " since spawn); close the terminal first" : ""),
    );
  };
  ctx.on("internal/dispatch", handler, { global: true });
  return () => { if (typeof ctx.off === "function") ctx.off("internal/dispatch", handler); };
}

// ---------------------------------------------------------------------------
// TerminalManager — one session's terminal: a single PTY + a single writer.
//
// The raw PTY it consumes (see RawPty below) is produced either by the cordis
// adapter (index.js:toRawPty) or by a test fake:
//   RawPty = {
//     pid: number,
//     output: AsyncIterable<Buffer|string>,   // UTF-8 PTY output, ends on exit
//     done: Promise<{ exitCode: number|null, signal: string|null }>,
//     write(data): Promise<void>,
//     signal(sig): Promise<number>,           // SIGINT|SIGTERM|SIGKILL|SIGTSTP|SIGHUP
//     resize(cols, rows): void,              // TIOCSWINSZ
//     terminate(): Promise<void>,            // TERM -> graceMs -> KILL
//   }
// ---------------------------------------------------------------------------
export class TerminalManager {
  constructor({ session, ctx, sandboxPolicy, sandbox, spawnTerminal, shellArgv, rows = 24, cols = 80, graceMs = 5000, term = "xterm-256color", baseEnv } = {}) {
    if (!session) throw new Error("pocket-terminal: TerminalManager requires a session");
    if (typeof spawnTerminal !== "function") throw new Error("pocket-terminal: TerminalManager requires spawnTerminal(spec)");
    if (!Array.isArray(shellArgv) || shellArgv.length === 0) throw new Error("pocket-terminal: TerminalManager requires a non-empty shellArgv");
    if (!sandboxPolicy || typeof sandboxPolicy.resolve !== "function") throw new Error("pocket-terminal: TerminalManager requires sandboxPolicy.resolve()");
    this.session = session;
    this.ctx = ctx ?? null;
    this.sandboxPolicy = sandboxPolicy;
    this.sandbox = sandbox ?? null;
    this.spawnTerminal = spawnTerminal;
    this.shellArgv = shellArgv;
    this.rows = rows;
    this.cols = cols;
    this.graceMs = graceMs;
    this.term = term;
    this.baseEnv = baseEnv ?? {};
    this.pty = null;
    this._live = new Set();
    this._frozenMode = null;
    this._dataListeners = new Set();
    this._exitListeners = new Set();
    this._writer = null;
    this._fenceDispose = null;
  }

  // True while a PTY is live or being created (the fence is active).
  get live() { return this._live.has(this.session) && this.pty !== null; }
  get writer() { return this._writer; }
  get frozenMode() { return this._frozenMode; }
  get pid() { return this.pty ? this.pty.pid : null; }

  // Confine the shell argv per the session's resolved sandbox policy.
  // danger-full-access passes the argv through unwrapped; the other two modes
  // are wrapped by ctx.sandbox.confine (the sample dsh-terminal-bash does the
  // same, but reads ctx.get("sandbox"); we take it as a constructor dep).
  confineArgv(policy) {
    if (policy.mode === "danger-full-access") return [...this.shellArgv];
    if (this.sandbox === null || this.sandbox === undefined) {
      throw new Error("pocket-terminal: sandbox mode " + JSON.stringify(policy.mode) + " requires a sandbox provider (ctx.sandbox)");
    }
    const confined = this.sandbox.confine(this.shellArgv, policy);
    if (!confined || !Array.isArray(confined.argv) || confined.argv.length === 0) {
      throw new Error("pocket-terminal: sandbox.confine returned an empty argv");
    }
    return confined.argv;
  }

  // Minimal child environment so the PTY behaves like a real interactive
  // terminal (a proper TERM for alt-screen apps, and stable session markers).
  _childEnv() {
    const env = { TERM: this.term, DSH_SHELL: "1", ...this.baseEnv };
    if (this.session.id !== undefined) {
      env.DSH_SESSION_ID = String(this.session.id);
      env.DSH_PTY_SESSION_ID = String(this.session.id);
    }
    return env;
  }

  // Create the PTY. Resolves to the manager (the terminal session).
  async spawn({ cwd } = {}) {
    if (this.live) throw new Error("pocket-terminal: a terminal is already live for this session");
    const policy = this.sandboxPolicy.resolve({ session: this.session });
    const argv = this.confineArgv(policy);
    // Freeze the mode and activate the fence BEFORE any await, so a mode
    // change during the async spawn is already blocked ("being created").
    this._frozenMode = policy.mode;
    if (this._fenceDispose === null) {
      this._fenceDispose = installSandboxModeFence(this.ctx, {
        session: this.session,
        isLive: () => this._live.has(this.session),
        frozenMode: () => this._frozenMode,
      });
    }
    this._live.add(this.session);
    let raw;
    try {
      raw = await this.spawnTerminal({ argv, cwd: cwd ?? policy.workspaceRoot, rows: this.rows, cols: this.cols, graceMs: this.graceMs, env: this._childEnv() });
    } catch (err) {
      this._live.delete(this.session);
      this._frozenMode = null;
      throw err;
    }
    const pty = { handle: raw, policy, pid: raw.pid, exited: false };
    this.pty = pty;
    this._pumpOutput(raw);
    raw.done.then(
      (outcome) => this._settle(pty, outcome),
      (err) => this._fail(pty, err),
    );
    return this;
  }

  // Forward PTY output to onData observers. The seam's output stream ends after
  // its queued bytes when the terminal exits, so this loop terminates naturally.
  _pumpOutput(raw) {
    const pump = async () => {
      try {
        for await (const chunk of raw.output) {
          for (const cb of this._dataListeners) cb(chunk);
        }
      } catch { /* stream ended or errored; the exit path owns cleanup */ }
    };
    pump();
  }

  onData(cb) { this._dataListeners.add(cb); return () => this._dataListeners.delete(cb); }
  onExit(cb) { this._exitListeners.add(cb); return () => this._exitListeners.delete(cb); }

  async _terminate(handle) { try { await handle.terminate(); } catch { /* already gone */ } }

  // Normal exit: the process settled. Remove from the live set (fence inactive),
  // release the writer, dispose the PTY, and notify exit observers.
  async _settle(pty, outcome) {
    if (pty.exited || this.pty !== pty) return; // stale (already settled or re-spawned)
    pty.exited = true;
    this._live.delete(this.session);
    this._writer = null;
    await this._terminate(pty.handle);
    for (const cb of this._exitListeners) cb(outcome);
  }

  // Abnormal exit: the seam's done promise rejected.
  async _fail(pty, err) {
    if (pty.exited || this.pty !== pty) return;
    pty.exited = true;
    this._live.delete(this.session);
    this._writer = null;
    await this._terminate(pty.handle);
    for (const cb of this._exitListeners) cb({ exitCode: null, signal: null, error: err });
  }

  // Single input writer: the second writer is rejected. Idempotent for the
  // owner re-acquiring. Watchers read through onData and never write.
  acquireWriter(id) {
    if (this._writer === null) { this._writer = id; return true; }
    if (this._writer === id) return true;
    throw new Error("pocket-terminal: another client owns the terminal input (second writer rejected)");
  }
  releaseWriter(id) { if (this._writer === id || this._writer === null) this._writer = null; }

  async write(data) {
    if (!this.pty) throw new Error("pocket-terminal: no terminal spawned");
    if (this._writer === null) throw new Error("pocket-terminal: no input owner; call acquireWriter first");
    await this.pty.handle.write(data);
  }
  async signal(signal) {
    if (!this.pty) throw new Error("pocket-terminal: no terminal spawned");
    if (this._writer === null) throw new Error("pocket-terminal: no input owner; call acquireWriter first");
    await this.pty.handle.signal(signal);
  }
  // cols first, then rows — matches node-pty's IPty.resize(cols, rows).
  async resize(cols, rows) {
    if (!this.pty) throw new Error("pocket-terminal: no terminal spawned");
    await this.pty.handle.resize(cols, rows);
  }
  async kill() {
    if (!this.pty) return;
    await this._terminate(this.pty.handle);
  }

  // Remove the mode fence (idempotent).
  dispose() { if (this._fenceDispose) { this._fenceDispose(); this._fenceDispose = null; } }
}
