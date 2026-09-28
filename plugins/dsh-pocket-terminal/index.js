// Pocket DSH — Pocket Terminal plugin (commits C1–C2 of DSH-TERMINAL).
//
// C1: cordis binding over the pure core (./core.js) — the PTY-session manager
// with the real ctx.subprocess.spawnTerminal seam and the resize adapter that
// reaches node-pty's IPty.resize for TIOCSWINSZ.
//
// C2: the transport. The "pocketTerminal" service is published with a visible
// `typertRemote` binding and hand-written SRC Remote markers, so the Gateway
// discovers the endpoints without a Typert code generator (this plugin is a
// plain-JS `link:` dependency with no DSH imports):
//
//   pocketTerminal/attach   stream   sessionId, ticket, since?, cols?, rows? -> frames
//   pocketTerminal/write    unary    sessionId, data, ticket
//   pocketTerminal/resize   unary    sessionId, cols, rows, ticket
//
// and `POST /pocket-terminal/auth` (an exact Fetch route, dsh-voice style)
// authenticates the caller with connection.requestRejection (403 untrusted
// Host/Origin, 401 no browser session) and mints the short-lived attach ticket
// every method above requires.
//
// Why a ticket on top of the carrier gate: the Gateway already runs
// requestRejection on the /api/remote.mux WebSocket upgrade, so an
// unauthenticated socket never reaches a method — but the mux payload is
// exactly {args}, so a method cannot re-derive the caller's identity or scope.
// The authenticated route is the only request-bearing surface this plugin has,
// and it turns "this connection was authorized" into an expiring,
// session-scoped capability that the methods can check. A method called with a
// foreign session's ticket, or with none, is refused.
//
// Every refusal is a PocketTerminalError carrying a stable code; the Gateway
// recognises it structurally (`isDSHRemoteError` + `code`, see
// dsh-typert-protocol/lib/errors) and forwards the code unchanged.

import { randomBytes } from "node:crypto";
import { TerminalManager, installSandboxModeFence, SANDBOX_MODES } from "./core.js";
import {
  DEFAULT_SCROLLBACK_BYTES,
  MAX_COLS,
  MAX_INPUT_BYTES,
  MAX_ROWS,
  MIN_COLS,
  MIN_ROWS,
  SessionStream,
  TicketStore,
} from "./stream.js";

export { TerminalManager, installSandboxModeFence, SANDBOX_MODES };
export { SessionStream, TicketStore, DEFAULT_SCROLLBACK_BYTES };

export const name = "pocket-terminal";
// Required services; the plugin only loads while all of them are available.
// "sandbox" is intentionally NOT declared: it is optional (ctx.get) and only
// needed when the resolved mode is confined, exactly like dsh-terminal-bash.
// "webServer" and "connection" host the authenticated ticket route — without
// them nothing could ever mint a ticket, so the transport stays unloaded.
export const inject = ["subprocess", "sandboxPolicy", "webServer", "connection"];

/** Cordis service key and Remote namespace of the terminal transport. */
export const SERVICE_KEY = "pocketTerminal";
/** Authenticated exact route that issues attach tickets. */
export const AUTH_PATH = "/pocket-terminal/auth";
/** Largest accepted JSON body on AUTH_PATH. */
export const AUTH_BODY_LIMIT = 4 * 1024;
/** Attach-ticket lifetime. */
export const TICKET_TTL_MS = 120_000;
/** Longest accepted session id on AUTH_PATH. */
export const MAX_SESSION_ID = 200;

// The stable Typert SRC marker key. Written by hand because the package that
// defines it (@deepseek-ai/dsh-typert-protocol) is not resolvable from this
// plugin's own directory — a `link:` dependency resolves imports relative to
// this file. The reader is readRemoteMethodDescriptor(prototype): an own,
// non-inherited property of the service prototype holding {version: 1, methods}.
const REMOTE_METHOD_DESCRIPTOR = "@deepseek-ai/dsh-typert-protocol/remote-methods";

// Remote endpoints exposed by this plugin (name -> SRC mode). `attach` is the
// only stream endpoint; the Gateway refuses a unary method on the stream carrier
// (gateway/signature-invalid) and a stream method through RPC, so the mode is
// part of the contract. The parameter names are read back off the prototypes by
// the Gateway, so each method must use plain identifiers with the cancellation
// parameter `signal` last.
export const ENDPOINTS = Object.freeze({
  attach: { method: "attach", mode: "stream" },
  write: { method: "write" },
  resize: { method: "resize" },
});

/** One Remote failure with a stable wire code (structurally a DSH RemoteError). */
export class PocketTerminalError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "PocketTerminalError";
    this.code = code;
    this.details = details;
    this.isDSHRemoteError = true;
  }
}

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
//   options — { session, shellArgv?, rows?, cols?, graceMs?, term?, baseEnv? }
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

// Session identity and the metadata the open frame reports. The Session object
// arrives through the host's `session` lookup (dsh-session registers it with
// wire field `sessionId`; dsh-api-session-controller reconfigures it to resume
// a persisted session), so an unknown or foreign id never reaches a method.
export function sessionIdOf(session) {
  const id = session?.id;
  if (typeof id !== "string" || id.length === 0) {
    throw new PocketTerminalError("pocket-terminal/invalid-input", "the resolved session has no id");
  }
  return id;
}

export function sessionCwd(session) {
  const cwd = session?.meta?.cwd ?? session?.header?.cwd ?? session?.cwd;
  return typeof cwd === "string" && cwd.length > 0 ? cwd : null;
}

// Terminal geometry from the wire, clamped to sane bounds. The open frame
// reports the value actually applied to the PTY.
export function normalizeGeometry(cols, rows) {
  const geometry = {};
  if (cols !== undefined) {
    if (!Number.isInteger(cols) || cols < MIN_COLS || cols > MAX_COLS) {
      throw new PocketTerminalError("pocket-terminal/invalid-input", `cols must be an integer in [${MIN_COLS}, ${MAX_COLS}]`);
    }
    geometry.cols = cols;
  }
  if (rows !== undefined) {
    if (!Number.isInteger(rows) || rows < MIN_ROWS || rows > MAX_ROWS) {
      throw new PocketTerminalError("pocket-terminal/invalid-input", `rows must be an integer in [${MIN_ROWS}, ${MAX_ROWS}]`);
    }
    geometry.rows = rows;
  }
  return geometry;
}

// Replay cursor from the wire: the last `seq` the client saw (absent = 0).
export function normalizeSince(since) {
  if (since === undefined) return 0;
  if (!Number.isSafeInteger(since) || since < 0) {
    throw new PocketTerminalError("pocket-terminal/invalid-input", "since must be a non-negative integer");
  }
  return since;
}

// The published service. Its methods sit on the prototype: the Gateway's SRC
// reflection reads own prototype descriptors for both the marker and the
// parameter names, so the parameter list must be plain identifiers with the
// cancellation parameter `signal` last (no defaults, destructuring or rest).
export class PocketTerminalService {
  constructor(ctx, { makeManager, tickets, ttlMs = TICKET_TTL_MS, entropy, scrollbackBytes = DEFAULT_SCROLLBACK_BYTES } = {}) {
    if (typeof makeManager !== "function") throw new Error("pocket-terminal: PocketTerminalService requires makeManager(session)");
    this.ctx = ctx;
    this.makeManager = makeManager;
    this.scrollbackBytes = scrollbackBytes;
    this.hubs = new Map();
    this.tickets = tickets ?? new TicketStore({
      ttlMs,
      entropy: entropy ?? (() => randomBytes(24).toString("base64url")),
    });
    // Visible binding consumed by the Gateway's source-mode discovery
    // (bindTypertRemote(service, key) is exactly this frozen shape).
    this.typertRemote = Object.freeze({ service: this, serviceKey: SERVICE_KEY, namespace: SERVICE_KEY });
  }

  // ---- transport -----------------------------------------------------------

  // Stream one terminal. The first attach spawns the PTY (confined by the
  // session's sandbox policy); later attaches are read-only watchers unless they
  // also call write. `since` is the last seq the client saw (0 = full replay).
  async *attach(session, ticket, since, cols, rows, signal) {
    const sessionId = sessionIdOf(session);
    this.authorize(sessionId, ticket);
    const from = normalizeSince(since);
    const geometry = normalizeGeometry(cols, rows);
    const hub = await this.ensureStream(session, geometry);
    const subscription = hub.subscribe({ since: from });
    try {
      yield hub.openFrame();
      for (const frame of subscription.replay) yield frame;
      for await (const frame of subscription.frames(signal)) yield frame;
    } finally {
      subscription.close();
    }
  }

  // Forward client input to the PTY. The first writer owns the input; a second
  // ticket is refused by the core's single-writer rule.
  async write(session, data, ticket, signal) {
    const sessionId = sessionIdOf(session);
    this.authorize(sessionId, ticket);
    if (typeof data !== "string") {
      throw new PocketTerminalError("pocket-terminal/invalid-input", "data must be a UTF-8 string");
    }
    const bytes = Buffer.byteLength(data, "utf8");
    if (bytes > MAX_INPUT_BYTES) {
      throw new PocketTerminalError("pocket-terminal/invalid-input", `data exceeds ${MAX_INPUT_BYTES} bytes`);
    }
    const hub = this.liveStream(sessionId);
    try {
      hub.manager.acquireWriter(writerIdOf(ticket));
    } catch (error) {
      throw new PocketTerminalError("pocket-terminal/writer-busy", error instanceof Error ? error.message : String(error));
    }
    await hub.manager.write(data);
    const submissions = hub.noteInput(data);
    return { ok: true, bytes, submissions };
  }

  // Apply the client's geometry (TIOCSWINSZ through the seam adapter). A
  // watcher may not resize a terminal whose input another ticket owns.
  async resize(session, cols, rows, ticket, signal) {
    const sessionId = sessionIdOf(session);
    this.authorize(sessionId, ticket);
    if (cols === undefined || rows === undefined) {
      throw new PocketTerminalError("pocket-terminal/invalid-input", "resize requires both cols and rows");
    }
    const geometry = normalizeGeometry(cols, rows);
    const hub = this.liveStream(sessionId);
    const owner = hub.manager.writer;
    if (owner !== null && owner !== writerIdOf(ticket)) {
      throw new PocketTerminalError("pocket-terminal/writer-busy", "only the input owner may resize a live terminal");
    }
    await hub.manager.resize(geometry.cols, geometry.rows);
    hub.cols = geometry.cols;
    hub.rows = geometry.rows;
    return { ok: true, cols: geometry.cols, rows: geometry.rows };
  }

  // ---- lifecycle -----------------------------------------------------------

  // The live stream for an attached session, or a stable refusal.
  liveStream(sessionId) {
    const hub = this.hubs.get(sessionId)?.hub;
    if (hub === undefined || hub === null || hub.exited !== null || !hub.manager.live) {
      throw new PocketTerminalError("pocket-terminal/not-attached", "no live terminal for this session; call pocketTerminal/attach first");
    }
    return hub;
  }

  // Resolve (or create, exactly once) the stream of a session. Concurrent
  // attaches share one spawn; a stream that already exited is replaced, so the
  // next attach opens a fresh PTY. This is the only writer of `this.hubs`.
  async ensureStream(session, geometry = {}) {
    const sessionId = sessionIdOf(session);
    const current = this.hubs.get(sessionId);
    if (current?.startup !== undefined && current.startup !== null) return await current.startup;
    if (current?.hub !== undefined && current.hub !== null && current.hub.exited === null && current.hub.manager.live) {
      return current.hub;
    }
    if (current?.hub !== undefined && current.hub !== null) {
      // Replace an exited stream: drop its hub and the sandbox-mode fence its
      // manager installed, so a re-attach does not stack listeners.
      current.hub.dispose();
      disposeManager(current.hub.manager);
    }
    const startup = this.startStream(session, sessionId, geometry);
    this.hubs.set(sessionId, { hub: null, startup });
    try {
      const hub = await startup;
      this.hubs.set(sessionId, { hub });
      return hub;
    } catch (error) {
      const settled = this.hubs.get(sessionId);
      if (settled?.startup === startup) this.hubs.delete(sessionId);
      throw error;
    }
  }

  async startStream(session, sessionId, { cols = 80, rows = 24 } = {}) {
    const manager = this.makeManager(session);
    const hub = new SessionStream({
      manager,
      sessionId,
      cwd: sessionCwd(session),
      sandboxMode: this.sandboxModeOf(session),
      cols,
      rows,
      scrollbackBytes: this.scrollbackBytes,
    });
    hub.start();
    try {
      await manager.spawn({ cwd: hub.cwd ?? undefined });
    } catch (error) {
      hub.dispose();
      disposeManager(manager);
      throw new PocketTerminalError("pocket-terminal/spawn-failed", error instanceof Error ? error.message : String(error));
    }
    return hub;
  }

  sandboxModeOf(session) {
    try {
      return this.ctx?.sandboxPolicy?.resolve?.({ session })?.mode ?? null;
    } catch {
      return null;
    }
  }

  // ---- authorization -------------------------------------------------------

  // Refuse anything without a live ticket issued to this very session.
  authorize(sessionId, ticket) {
    if (!this.tickets.verify(sessionId, ticket)) {
      throw new PocketTerminalError("pocket-terminal/unauthorized", "attach ticket is missing, expired or was not issued for this session");
    }
  }

  issueTicket(sessionId) { return this.tickets.issue(sessionId); }

  // Unload: close the PTYs this plugin spawned (a plugin reload must not leak
  // shells) and remove every sandbox-mode fence this plugin installed.
  dispose() {
    for (const { hub } of this.hubs.values()) {
      if (hub === undefined || hub === null) continue;
      hub.dispose();
      disposeManager(hub.manager);
      hub.manager.kill().catch(() => {});
    }
    this.hubs.clear();
  }
}

// Input ownership is tracked per ticket, not per client object, so two tabs
// sharing one ticket are one writer.
function writerIdOf(ticket) { return `ticket:${String(ticket)}`; }

// Remove a manager's sandbox-mode fence; never throws during teardown.
function disposeManager(manager) {
  try { manager.dispose(); } catch { /* already disposed */ }
}

// Marker array, frozen exactly as typert-protocol's `mark()` writes it.
const REMOTE_MARKERS = Object.freeze(
  Object.entries(ENDPOINTS).map(([method, descriptor]) => Object.freeze({
    method,
    ...descriptor.mode === undefined ? {} : { mode: descriptor.mode },
    invocation: Object.freeze({ kind: "direct" }),
  })),
);

Object.defineProperty(PocketTerminalService.prototype, REMOTE_METHOD_DESCRIPTOR, {
  value: Object.freeze({ version: 1, methods: REMOTE_MARKERS }),
  writable: false,
  enumerable: false,
  configurable: true,
});

// POST /pocket-terminal/auth — the plugin's only request-bearing surface, so the
// only place connection.requestRejection (the same fence dsh-voice uses) applies.
// It authenticates the caller and mints the session-scoped ticket; session
// resolution stays with the host's `session` lookup, which the methods use.
//   sessionExists — optional (id) => boolean|undefined probe; undefined means
//   the host session store is unreachable and the check is skipped.
export function createAuthHandler(service, connection, { limit = AUTH_BODY_LIMIT, sessionExists } = {}) {
  return async function authHandler(req, res) {
    const json = (status, body) => {
      if (res.destroyed) return;
      res.writeHead(status, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      res.end(JSON.stringify(body));
    };
    const rejected = connection?.requestRejection?.(req);
    if (rejected !== undefined) {
      json(rejected, { error: rejected === 401 ? "Sign in to DSH again." : "This Host is not trusted." });
      return;
    }
    if (req.method !== "POST") {
      json(405, { error: "POST required." });
      return;
    }
    const mediaType = String(req.headers["content-type"] ?? "").split(";", 1)[0].trim().toLowerCase();
    if (mediaType !== "application/json") {
      json(415, { error: "content-type must be application/json." });
      return;
    }
    let body;
    try {
      const chunks = [];
      let size = 0;
      for await (const chunk of req) {
        size += chunk.length;
        if (size > limit) {
          json(413, { error: "Request body is too large." });
          return;
        }
        chunks.push(chunk);
      }
      body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    } catch {
      json(400, { error: "A JSON body is required." });
      return;
    }
    const sessionId = body?.sessionId;
    if (typeof sessionId !== "string" || sessionId.length === 0 || sessionId.length > MAX_SESSION_ID) {
      json(400, { error: "sessionId is required." });
      return;
    }
    if (typeof sessionExists === "function") {
      let known;
      try { known = await sessionExists(sessionId); } catch { known = undefined; }
      if (known === false) {
        json(404, { error: "Unknown session." });
        return;
      }
    }
    json(200, service.issueTicket(sessionId));
  };
}

// Ask the host session store whether an id exists. Returns undefined when the
// store is not loaded, so the route degrades to "authenticate and mint" instead
// of refusing every caller.
export function createSessionProbe(ctx) {
  return (sessionId) => {
    try {
      const sessions = typeof ctx.get === "function" ? ctx.get("sessions") : undefined;
      if (typeof sessions?.get !== "function") return undefined;
      return sessions.get(sessionId) !== undefined;
    } catch {
      return undefined;
    }
  };
}

// Cordis apply: publish the service (the Gateway discovers its Remote methods
// through typertRemote + the SRC markers) and register the authenticated route
// that mints the tickets those methods require.
export function apply(ctx) {
  const service = new PocketTerminalService(ctx, {
    makeManager: (session) => createManager(ctx, { session }),
  });
  ctx.provide(SERVICE_KEY, service);
  ctx.effect(() => () => { service.dispose(); }, "pocket-terminal: close live terminals on unload");
  ctx.effect(
    () => ctx.webServer.register({
      kind: "exact",
      path: AUTH_PATH,
      handler: createAuthHandler(service, ctx.connection, { sessionExists: createSessionProbe(ctx) }),
    }),
    `pocket-terminal: ${AUTH_PATH} route`,
  );
  return service;
}
