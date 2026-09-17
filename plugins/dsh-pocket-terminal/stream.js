// Pocket DSH — Pocket Terminal transport frames (commit C2 of DSH-TERMINAL).
//
// Pure, dependency-free transport core: the frame vocabulary, the bounded
// scrollback log, per-subscriber queues that coalesce under pressure, the
// shell-block tracker and the attach-ticket store. index.js binds this to
// cordis and to the Gateway's Remote stream carrier.
//
// Wire constraints this file encodes (read out of dsh-api-gateway):
//   * the Remote stream mux (`/api/remote.mux`) accepts TEXT frames only — a
//     binary frame closes the socket with 1003 — so PTY bytes are carried
//     base64 inside a "data" frame;
//   * the mux pulls exactly one frame per awaited socket write
//     (`for await (const value of source) await this.send(...)`), so a queue
//     that coalesces adjacent chunks is the backpressure valve; bytes are
//     never dropped, only merged;
//   * every frame carries a monotonic `seq`, so a reconnecting client passes
//     `since` and receives exactly the suffix it missed, bounded by the
//     scrollback budget.
//
// Frame vocabulary (all frames carry `seq`):
//   open       { sessionId, pid, cwd, sandboxMode, cols, rows, replay }
//   data       { encoding: "base64", data, bytes }
//   blockStart { blockId, text }
//   blockEnd   { blockId, text, exitCode }
//   exit       { exitCode, signal }
//   error      { code, message }
//
// A "block" is one submitted shell line plus the output that follows it: the
// shell-history list in the client renders blocks, not raw bytes. Without shell
// integration (OSC 133) the client cannot know a command's exit code, so a
// block closed by silence carries `exitCode: null`; only the PTY's own exit
// closes an open block with a real code.

/** Default scrollback budget replayed to a reconnecting client (64 KiB). */
export const DEFAULT_SCROLLBACK_BYTES = 64 * 1024;
/** Silence (ms) after which an open block is closed with an unknown exit code. */
export const DEFAULT_BLOCK_IDLE_MS = 250;
/** Control frames (blocks/exit) kept for replay — bounded independently. */
export const MAX_LOGGED_FRAMES = 512;
/** Unconsumed frames per subscriber before data frames start coalescing. */
export const MAX_PENDING_FRAMES = 256;
/** Maximum accepted input chunk forwarded to the PTY in one call. */
export const MAX_INPUT_BYTES = 64 * 1024;
/** Live attach tickets kept per session (one per open client; oldest evicted). */
export const MAX_TICKETS_PER_SESSION = 8;
/** Terminal geometry bounds accepted from the client. */
export const MIN_COLS = 2;
export const MAX_COLS = 1000;
export const MIN_ROWS = 1;
export const MAX_ROWS = 1000;

// UTF-8 bytes for one PTY chunk, tolerating both Buffer and string seams.
export function toBytes(chunk) {
  if (Buffer.isBuffer(chunk)) return chunk;
  if (chunk instanceof Uint8Array) return Buffer.from(chunk);
  return Buffer.from(String(chunk), "utf8");
}

// Encode one log entry into its wire frame. Data entries hold raw bytes and are
// base64-encoded here — encoding happens once, at hand-off to the carrier.
export function encodeFrame(entry) {
  if (entry.kind === "data") {
    return {
      type: "data",
      seq: entry.seq,
      encoding: "base64",
      data: toBytes(entry.bytes).toString("base64"),
      bytes: toBytes(entry.bytes).length,
    };
  }
  return { ...entry.frame, seq: entry.seq };
}

// Bounded replay log: keeps the newest data bytes (the scrollback budget) plus
// the newest control frames. Eviction is oldest-first and reported once, so a
// truncated replay can tell the client to redraw instead of trusting the delta.
export class ScrollbackLog {
  constructor({ maxBytes = DEFAULT_SCROLLBACK_BYTES, maxFrames = MAX_LOGGED_FRAMES } = {}) {
    this.maxBytes = maxBytes;
    this.maxFrames = maxFrames;
    this.entries = [];
    this.dataBytes = 0;
    this.frameCount = 0;
    this.truncated = false;
  }

  push(entry) {
    this.entries.push(entry);
    if (entry.kind === "data") this.dataBytes += toBytes(entry.bytes).length;
    else this.frameCount += 1;
    let evicted = false;
    while (this.entries.length > 1 && (this.dataBytes > this.maxBytes || this.frameCount > this.maxFrames)) {
      const oldest = this.entries.shift();
      if (oldest.kind === "data") this.dataBytes -= toBytes(oldest.bytes).length;
      else this.frameCount -= 1;
      evicted = true;
    }
    if (evicted) this.truncated = true;
  }

  get bytes() { return this.dataBytes; }
  get size() { return this.entries.length; }

  // Entries strictly newer than `seq`, in order.
  since(seq) {
    const from = Number.isSafeInteger(seq) && seq > 0 ? seq : 0;
    return this.entries.filter((entry) => entry.seq > from);
  }
}

// One subscriber's frame queue. The carrier consumes one frame per awaited
// socket write, so an unread backlog is expressed as fewer, larger data frames
// instead of dropped bytes: once the queue is at its frame ceiling, an incoming
// data frame is merged into the queued tail data frame (always lossless).
export class FrameQueue {
  constructor({ maxFrames = MAX_PENDING_FRAMES } = {}) {
    this.maxFrames = maxFrames;
    this.pending = [];
    this.closed = false;
    this.waiters = [];
    this.merged = 0;
  }

  push(entry) {
    if (this.closed) return;
    const tail = this.pending[this.pending.length - 1];
    if (entry.kind === "data" && tail !== undefined && tail.kind === "data" && this.pending.length >= this.maxFrames) {
      tail.bytes = Buffer.concat([toBytes(tail.bytes), toBytes(entry.bytes)]);
      tail.seq = entry.seq;
      this.merged += 1;
      return;
    }
    this.pending.push(entry);
    const waiter = this.waiters.shift();
    if (waiter !== undefined) waiter();
  }

  close() {
    if (this.closed) return;
    this.closed = true;
    while (this.waiters.length) this.waiters.shift()();
  }

  get length() { return this.pending.length; }

  // Yield entries until the queue is closed and drained. `signal` (the Remote
  // call's cancellation signal) ends the iteration without dropping the queue —
  // the caller owns `close()`.
  async *drain(signal) {
    for (;;) {
      if (signal?.aborted === true) return;
      if (this.pending.length > 0) {
        yield this.pending.shift();
        continue;
      }
      if (this.closed) return;
      await new Promise((resolve) => {
        this.waiters.push(resolve);
        if (signal?.aborted === true) resolve();
        else if (typeof signal?.addEventListener === "function") signal.addEventListener("abort", () => resolve(), { once: true });
      });
    }
  }
}

// Per-session stream state: fan-out of PTY output, the replay log, block
// tracking and the open/exit frames. Owns no cordis and no PTY lifecycle — the
// manager is injected, so tests drive it with a fake PTY.
export class SessionStream {
  constructor({
    manager,
    sessionId,
    cwd = null,
    sandboxMode = null,
    cols = 80,
    rows = 24,
    scrollbackBytes = DEFAULT_SCROLLBACK_BYTES,
    blockIdleMs = DEFAULT_BLOCK_IDLE_MS,
    setTimer = setTimeout,
    clearTimer = clearTimeout,
  } = {}) {
    if (!manager) throw new Error("pocket-terminal: SessionStream requires a manager");
    if (!sessionId) throw new Error("pocket-terminal: SessionStream requires a sessionId");
    this.manager = manager;
    this.sessionId = sessionId;
    this.cwd = cwd;
    this.sandboxMode = sandboxMode;
    this.cols = cols;
    this.rows = rows;
    this.blockIdleMs = blockIdleMs;
    this.setTimer = setTimer;
    this.clearTimer = clearTimer;
    this.log = new ScrollbackLog({ maxBytes: scrollbackBytes });
    this.queues = new Set();
    this.seq = 0;
    this.exited = null;
    this.blockCounter = 0;
    this.openBlock = null;
    this.blockTimer = null;
    this.started = false;
  }

  // Attach to the manager's output/exit observers. Idempotent.
  start() {
    if (this.started) return this;
    this.started = true;
    this.manager.onData((chunk) => { this._onData(chunk); });
    this.manager.onExit((outcome) => { this._onExit(outcome); });
    return this;
  }

  _nextSeq() { this.seq += 1; return this.seq; }

  _append(entry) {
    this.log.push(entry);
    for (const queue of this.queues) queue.push(entry);
  }

  _frame(frame) { this._append({ kind: "frame", seq: this._nextSeq(), frame }); }

  _onData(chunk) {
    const bytes = toBytes(chunk);
    if (bytes.length === 0) return;
    this._append({ kind: "data", seq: this._nextSeq(), bytes });
    if (this.openBlock !== null) this._armBlockTimer();
  }

  // A submitted line opens a block: the pending block (if any) is closed with an
  // unknown exit code, because no shell integration told us the real one.
  noteInput(data) {
    const text = typeof data === "string" ? data : toBytes(data).toString("utf8");
    const lines = text.split(/\r\n|\r|\n/);
    const submissions = lines.length - 1;
    for (let index = 0; index < submissions; index += 1) {
      const submitted = index === 0 && this.partial !== undefined ? this.partial + lines[index] : lines[index];
      this.partial = undefined;
      this._closeBlock(null);
      this._openBlock(submitted);
    }
    if (lines[submissions].length > 0) this.partial = (this.partial ?? "") + lines[submissions];
    return submissions;
  }

  _openBlock(text) {
    this.blockCounter += 1;
    const blockId = `${this.sessionId}:${this.blockCounter}`;
    this.openBlock = { blockId, text };
    this._frame({ type: "blockStart", blockId, text });
  }

  _closeBlock(exitCode) {
    if (this.openBlock === null) return null;
    const { blockId, text } = this.openBlock;
    this.openBlock = null;
    this._disarmBlockTimer();
    this._frame({ type: "blockEnd", blockId, text, exitCode });
    return blockId;
  }

  _armBlockTimer() {
    this._disarmBlockTimer();
    this.blockTimer = this.setTimer(() => {
      this.blockTimer = null;
      this._closeBlock(null);
    }, this.blockIdleMs);
    if (typeof this.blockTimer?.unref === "function") this.blockTimer.unref();
  }

  _disarmBlockTimer() {
    if (this.blockTimer !== null) {
      this.clearTimer(this.blockTimer);
      this.blockTimer = null;
    }
  }

  // The PTY settled: close the open block with the real code, publish `exit`,
  // end every subscriber.
  _onExit(outcome) {
    if (this.exited !== null) return;
    const exitCode = outcome?.exitCode ?? null;
    const signal = outcome?.signal ?? null;
    this.exited = { exitCode, signal };
    this._closeBlock(exitCode);
    this._frame({ type: "exit", exitCode, signal });
    for (const queue of this.queues) queue.close();
  }

  openFrame() {
    // The open frame reserves the next seq as the client's resume cursor, but the
    // replay bounds describe the log itself: `to` is the last logged seq, captured
    // before this (unlogged) frame consumes the next one, so a bootstrap frame
    // cannot shift the replay range.
    const from = this.log.since(0)[0]?.seq ?? 0;
    const to = this.seq;
    return {
      type: "open",
      seq: this._nextSeq(),
      sessionId: this.sessionId,
      pid: this.manager.pid ?? null,
      cwd: this.cwd,
      sandboxMode: this.sandboxMode,
      cols: this.cols,
      rows: this.rows,
      replay: { from, to, bytes: this.log.bytes, truncated: this.log.truncated },
    };
  }

  // Register a subscriber, then snapshot the replay. Registration happens first
  // so no frame can fall between the snapshot and the live queue; duplicates are
  // impossible because the fan-out is synchronous with the log push.
  subscribe({ since = 0 } = {}) {
    const queue = new FrameQueue();
    const replay = this.log.since(since).map(encodeFrame);
    this.queues.add(queue);
    const close = () => {
      this.queues.delete(queue);
      queue.close();
    };
    const stream = this;
    return {
      replay,
      close,
      frames: (signal) => stream._frames(queue, encodeFrame, signal),
    };
  }

  async *_frames(queue, encode, signal) {
    try {
      for await (const entry of queue.drain(signal)) yield encode(entry);
    } finally {
      queue.close();
    }
  }

  dispose() {
    this._disarmBlockTimer();
    for (const queue of this.queues) queue.close();
    this.queues.clear();
  }
}

// Attach tickets: the authenticated HTTP route (index.js) mints one per session
// and the Remote methods require it, so an unauthenticated carrier cannot open a
// terminal even if it reaches the mux. Tickets are process-local, expiring and
// compared without early exit.
export class TicketStore {
  constructor({ ttlMs = 120_000, now = () => Date.now(), entropy, maxPerSession = MAX_TICKETS_PER_SESSION } = {}) {
    if (typeof entropy !== "function") throw new Error("pocket-terminal: TicketStore requires entropy()");
    this.ttlMs = ttlMs;
    this.now = now;
    this.entropy = entropy;
    this.maxPerSession = maxPerSession;
    // sessionId -> Map<ticket, expiresAt> (insertion order = mint order).
    this.tickets = new Map();
  }

  // Mint one ticket for one session. Several clients may watch the same
  // terminal, so minting never invalidates a sibling; the oldest ticket of a
  // session is evicted once the per-session ceiling is reached.
  issue(sessionId) {
    this.prune();
    let held = this.tickets.get(sessionId);
    if (held === undefined) {
      held = new Map();
      this.tickets.set(sessionId, held);
    }
    while (held.size >= this.maxPerSession) held.delete(held.keys().next().value);
    const ticket = this.entropy();
    const expiresAt = this.now() + this.ttlMs;
    held.set(ticket, expiresAt);
    return { ticket, expiresAt, sessionId };
  }

  // Constant-time-ish comparison over every live ticket of the session; the
  // loop never exits early, so it reveals neither which ticket matched nor how
  // many are held.
  verify(sessionId, ticket) {
    if (typeof sessionId !== "string" || typeof ticket !== "string" || ticket.length === 0) return false;
    const held = this.tickets.get(sessionId);
    if (held === undefined) return false;
    const at = this.now();
    const candidate = Buffer.from(ticket, "utf8");
    let matched = false;
    for (const [known, expiresAt] of held) {
      if (expiresAt <= at) {
        held.delete(known);
        continue;
      }
      const bytes = Buffer.from(known, "utf8");
      let diff = bytes.length ^ candidate.length;
      for (let index = 0; index < bytes.length && index < candidate.length; index += 1) diff |= bytes[index] ^ candidate[index];
      if (diff === 0) matched = true;
    }
    if (held.size === 0) this.tickets.delete(sessionId);
    return matched;
  }

  // Drop every expired ticket; empty sessions leave the map.
  prune() {
    const at = this.now();
    for (const [sessionId, held] of this.tickets) {
      for (const [ticket, expiresAt] of held) if (expiresAt <= at) held.delete(ticket);
      if (held.size === 0) this.tickets.delete(sessionId);
    }
  }
}
