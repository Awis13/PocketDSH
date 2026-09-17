// Pocket DSH — Pocket Terminal plugin (commit C1 of DSH-TERMINAL).
//
// Cordis binding over the pure core (./core.js). Exposes the PTY-session
// manager with the real ctx.subprocess.spawnTerminal seam, and a resize
// adapter that reaches the node-pty handle for TIOCSWINSZ — the seam's
// SubprocessTerminalHandle has no resize of its own, so the plugin supplies it.
//
// The manager is provided as the "pocketTerminal" service for C2's
// pocketTerminal/attach stream method to consume. C1 registers no endpoint.

import { TerminalManager, installSandboxModeFence, SANDBOX_MODES } from "./core.js";

export { TerminalManager, installSandboxModeFence, SANDBOX_MODES };

export const name = "pocket-terminal";
// Required services; the plugin only loads while both are available.
// "sandbox" is intentionally NOT declared: it is optional (ctx.get) and only
// needed when the resolved mode is confined, exactly like dsh-terminal-bash.
export const inject = ["subprocess", "sandboxPolicy"];

// Wrap the seam's SubprocessTerminalHandle into the core's RawPty shape, adding
// resize via the node-pty IPty. LocalTerminalHandle stores the node-pty handle
// on a (JS-private) this.terminal field; IPty.resize(cols, rows) is the
// TIOCSWINSZ call on Unix (pty.resize(fd, cols, rows) in node-pty's native).
export function toRawPty(seam) {
  return {
    pid: seam.pid,
    output: seam.output,
    done: seam.done,
    write: (data) => seam.write(data),
    signal: (sig) => seam.signalForeground(sig),
    terminate: () => seam.terminate(),
    resize: (cols, rows) => {
      const pty = seam.terminal ?? seam.ipTty ?? seam;
      if (typeof pty?.resize === "function") return pty.resize(cols, rows);
      throw new Error("pocket-terminal: seam handle exposes no node-pty resize handle");
    },
  };
}

// Build a manager bound to one session, wired to the real seam.
//   ctx — the cordis context (has .subprocess, .sandboxPolicy, .get).
//   options — { session, shellArgv?, rows?, cols?, graceMs?, term?, baseEnv?, cwd? }
export function createManager(ctx, { session, ...rest } = {}) {
  return new TerminalManager({
    session,
    ctx,
    sandboxPolicy: ctx.sandboxPolicy,
    sandbox: typeof ctx.get === "function" ? ctx.get("sandbox") : ctx.sandbox,
    spawnTerminal: (spec) => ctx.subprocess.spawnTerminal(spec).then(toRawPty),
    shellArgv: rest.shellArgv ?? ["/bin/bash", "-l"],
    rows: rest.rows ?? 24,
    cols: rest.cols ?? 80,
    graceMs: rest.graceMs ?? 5000,
    term: rest.term ?? "xterm-256color",
    baseEnv: rest.baseEnv,
  });
}

// Cordis apply: publish the factory as the "pocketTerminal" service. Inert
// otherwise — no endpoint is registered in C1.
export function apply(ctx) {
  ctx.provide("pocketTerminal", {
    createManager,
    toRawPty,
    TerminalManager,
    installSandboxModeFence,
    SANDBOX_MODES,
  });
}
