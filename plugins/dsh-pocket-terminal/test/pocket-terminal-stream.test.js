// Pocket DSH — Pocket Terminal transport-core tests (commit C2 of DSH-TERMINAL).
//
// Exercises ./stream.js with no cordis and no PTY: fake async sources, a fake
// manager exposing only the observer seam, and fake timers, so block/idle
// behaviour is deterministic. Run:
//   node --test plugins/dsh-pocket-terminal/test/*.test.js
import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_SCROLLBACK_BYTES,
  FrameQueue,
  MAX_TICKETS_PER_SESSION,
  ScrollbackLog,
  SessionStream,
  TicketStore,
  encodeFrame,
  toBytes,
} from "../stream.js";

// ---- fakes -----------------------------------------------------------------

function makeFakeManager({ pid = 4242 } = {}) {
  const data = new Set();
  const exit = new Set();
  return {
    pid,
    writer: null,
    live: true,
    onData(cb) { data.add(cb); return () => data.delete(cb); },
    onExit(cb) { exit.add(cb); return () => exit.delete(cb); },
    emitData(chunk) { for (const cb of [...data]) cb(chunk); },
    emitExit(outcome) { for (const cb of [...exit]) cb(outcome); },
    dataListenerCount() { return data.size; },
  };
}

function makeFakeTimers() {
  let nextId = 0;
  const armed = new Map();
  return {
    setTimer(fn, ms) { nextId += 1; armed.set(nextId, { fn, ms }); return { id: nextId, unref() {} }; },
    clearTimer(handle) { armed.delete(handle.id); },
    count() { return armed.size; },
    fireDue() { const list = [...armed.values()]; armed.clear(); for (const timer of list) timer.fn(); },
  };
}

async function flush(times = 20) { for (let index = 0; index < times; index += 1) await new Promise((r) => setImmediate(r)); }

async function collectFrames(iterator, count, { timeoutMs = 500 } = {}) {
  const frames = [];
  const deadline = Date.now() + timeoutMs;
  while (frames.length < count && Date.now() < deadline) {
    const result = await Promise.race([iterator.next(), new Promise((r) => setTimeout(() => r({ done: true }), 50))]);
    if (result.done) break;
    frames.push(result.value);
  }
  return frames;
}

function makeStream({ manager = makeFakeManager(), sessionId = "sess-1", ...rest } = {}) {
  return new SessionStream({ manager, sessionId, ...rest });
}

// ---- bytes and framing -----------------------------------------------------

test("toBytes accepts Buffer, Uint8Array and string", () => {
  assert.equal(toBytes(Buffer.from("ab")).length, 2);
  assert.equal(toBytes(new Uint8Array([1, 2, 3])).length, 3);
  assert.equal(toBytes("héllo").length, 6);
});

test("encodeFrame base64-encodes data and stamps seq on control frames", () => {
  const data = encodeFrame({ kind: "data", seq: 7, bytes: Buffer.from("hi") });
  assert.deepEqual(data, { type: "data", seq: 7, encoding: "base64", data: "aGk=", bytes: 2 });
  const control = encodeFrame({ kind: "frame", seq: 8, frame: { type: "blockStart", blockId: "b" } });
  assert.deepEqual(control, { type: "blockStart", blockId: "b", seq: 8 });
});

// ---- ScrollbackLog ---------------------------------------------------------

test("ScrollbackLog evicts oldest bytes first and reports truncation once", () => {
  const log = new ScrollbackLog({ maxBytes: 8 });
  log.push({ kind: "data", seq: 1, bytes: Buffer.from("aaaa") });
  log.push({ kind: "data", seq: 2, bytes: Buffer.from("bbbb") });
  assert.equal(log.truncated, false);
  assert.equal(log.bytes, 8);
  log.push({ kind: "data", seq: 3, bytes: Buffer.from("cccc") });
  assert.equal(log.truncated, true);
  assert.equal(log.bytes, 8);
  assert.deepEqual(log.entries.map((entry) => entry.seq), [2, 3]);
});

test("ScrollbackLog bounds control frames independently and always keeps the newest entry", () => {
  const log = new ScrollbackLog({ maxBytes: 1024, maxFrames: 2 });
  for (let seq = 1; seq <= 4; seq += 1) log.push({ kind: "frame", seq, frame: { type: "exit" } });
  assert.equal(log.frameCount, 2);
  assert.deepEqual(log.entries.map((entry) => entry.seq), [3, 4]);
  const huge = new ScrollbackLog({ maxBytes: 1 });
  huge.push({ kind: "data", seq: 1, bytes: Buffer.from("x") });
  huge.push({ kind: "data", seq: 2, bytes: Buffer.from("0123456789") });
  assert.deepEqual(huge.entries.map((entry) => entry.seq), [2]);
});

test("ScrollbackLog.since returns entries strictly newer than seq", () => {
  const log = new ScrollbackLog();
  for (let seq = 1; seq <= 3; seq += 1) log.push({ kind: "data", seq, bytes: Buffer.from("x") });
  assert.deepEqual(log.since(0).map((entry) => entry.seq), [1, 2, 3]);
  assert.deepEqual(log.since(2).map((entry) => entry.seq), [3]);
  assert.deepEqual(log.since("nonsense").map((entry) => entry.seq), [1, 2, 3]);
  assert.equal(log.size, 3);
});

// ---- FrameQueue ------------------------------------------------------------

test("FrameQueue drains pushed entries and ends on close", async () => {
  const queue = new FrameQueue();
  queue.push({ kind: "frame", seq: 1, frame: { type: "exit" } });
  queue.close();
  const seen = [];
  for await (const entry of queue.drain()) seen.push(entry.seq);
  assert.deepEqual(seen, [1]);
});

test("FrameQueue wake-up wakes a waiting drain", async () => {
  const queue = new FrameQueue();
  const drained = (async () => { const seen = []; for await (const entry of queue.drain()) seen.push(entry.seq); return seen; })();
  await flush();
  queue.push({ kind: "data", seq: 5, bytes: Buffer.from("a") });
  queue.close();
  assert.deepEqual(await drained, [5]);
});

test("FrameQueue merges adjacent data frames at the ceiling without losing bytes", async () => {
  const queue = new FrameQueue({ maxFrames: 2 });
  queue.push({ kind: "data", seq: 1, bytes: Buffer.from("aa") });
  queue.push({ kind: "data", seq: 2, bytes: Buffer.from("bb") });
  queue.push({ kind: "data", seq: 3, bytes: Buffer.from("cc") });
  queue.push({ kind: "data", seq: 4, bytes: Buffer.from("dd") });
  queue.close();
  const frames = [];
  for await (const entry of queue.drain()) frames.push(encodeFrame(entry));
  assert.equal(queue.merged, 2);
  assert.equal(frames.length, 2);
  assert.equal(frames[1].seq, 4);
  assert.equal(Buffer.from(frames[1].data, "base64").toString("utf8"), "bbccdd");
});

test("FrameQueue stops draining on an aborted signal and ignores pushes after close", async () => {
  const queue = new FrameQueue();
  const controller = new AbortController();
  const drained = (async () => { const seen = []; for await (const entry of queue.drain(controller.signal)) seen.push(entry.seq); return seen; })();
  await flush();
  controller.abort();
  assert.deepEqual(await drained, []);
  queue.close();
  queue.push({ kind: "data", seq: 9, bytes: Buffer.from("x") });
  assert.equal(queue.length, 0);
});

// ---- SessionStream ---------------------------------------------------------

test("SessionStream.start is idempotent and records PTY data as data frames", async () => {
  const manager = makeFakeManager();
  const stream = makeStream({ manager });
  stream.start();
  stream.start();
  assert.equal(manager.dataListenerCount(), 1);
  manager.emitData(Buffer.from("hello"));
  manager.emitData("");
  await flush();
  const entries = stream.log.since(0);
  assert.equal(entries.length, 1);
  assert.equal(encodeFrame(entries[0]).data, Buffer.from("hello").toString("base64"));
  assert.equal(stream.seq, 1);
});

test("SessionStream.noteInput opens a block per submitted line and carries the partial", () => {
  const stream = makeStream();
  stream.start();
  assert.equal(stream.noteInput("ec"), 0);
  assert.equal(stream.noteInput("ho hi\n"), 1);
  const started = stream.log.since(0).map(encodeFrame);
  assert.deepEqual(started.map((frame) => frame.type), ["blockStart"]);
  assert.equal(started[0].text, "echo hi");
  assert.equal(stream.noteInput("ls\n"), 1);
  const all = stream.log.since(0).map(encodeFrame);
  assert.deepEqual(all.map((frame) => frame.type), ["blockStart", "blockEnd", "blockStart"]);
  assert.equal(all[1].exitCode, null);
  assert.equal(all[2].text, "ls");
});

test("SessionStream closes an idle block with an unknown exit code via the armed timer", async () => {
  const timers = makeFakeTimers();
  const manager = makeFakeManager();
  const stream = makeStream({ manager, setTimer: timers.setTimer, clearTimer: timers.clearTimer });
  stream.start();
  stream.noteInput("sleep 1\n");
  assert.equal(timers.count(), 0);
  manager.emitData(Buffer.from("tick"));
  assert.equal(timers.count(), 1);
  timers.fireDue();
  const frames = stream.log.since(0).map(encodeFrame);
  assert.deepEqual(frames.map((frame) => frame.type), ["blockStart", "data", "blockEnd"]);
  assert.equal(frames[2].exitCode, null);
  assert.equal(timers.count(), 0);
});

test("SessionStream closes the open block with the PTY exit code and ends subscribers", async () => {
  const manager = makeFakeManager();
  const stream = makeStream({ manager });
  stream.start();
  stream.noteInput("exit\n");
  const subscription = stream.subscribe();
  manager.emitExit({ exitCode: 3, signal: null });
  const frames = [];
  for await (const frame of subscription.frames()) frames.push(frame);
  assert.deepEqual(frames.map((frame) => frame.type), ["blockEnd", "exit"]);
  assert.equal(frames[0].exitCode, 3);
  assert.deepEqual(stream.exited, { exitCode: 3, signal: null });
  manager.emitExit({ exitCode: 0, signal: null });
  assert.deepEqual(stream.exited, { exitCode: 3, signal: null });
});

test("SessionStream.openFrame reports identity, geometry and replay bounds without logging itself", () => {
  const manager = makeFakeManager();
  const stream = makeStream({ manager, cwd: "/ws", sandboxMode: "workspace-write", cols: 100, rows: 30 });
  stream.start();
  manager.emitData(Buffer.from("abc"));
  const frame = stream.openFrame();
  assert.equal(frame.type, "open");
  assert.equal(frame.sessionId, "sess-1");
  assert.equal(frame.pid, 4242);
  assert.equal(frame.cwd, "/ws");
  assert.equal(frame.sandboxMode, "workspace-write");
  assert.equal(frame.cols, 100);
  assert.equal(frame.rows, 30);
  assert.equal(frame.replay.to, 1);
  assert.equal(frame.replay.bytes, 3);
  assert.equal(frame.replay.truncated, false);
  assert.equal(stream.log.size, 1);
});

test("SessionStream.subscribe replays the missed suffix then streams live frames", async () => {
  const manager = makeFakeManager();
  const stream = makeStream({ manager });
  stream.start();
  manager.emitData(Buffer.from("old"));
  const first = stream.subscribe({ since: 0 });
  assert.equal(first.replay.length, 1);
  first.close();
  manager.emitData(Buffer.from("new"));
  const second = stream.subscribe({ since: 1 });
  assert.equal(second.replay.length, 1);
  assert.equal(second.replay[0].data, Buffer.from("new").toString("base64"));
  manager.emitData(Buffer.from("live"));
  const frames = await collectFrames(second.frames(), 1);
  assert.equal(encodeFrame({ kind: "data", seq: 1, bytes: Buffer.from("live") }).data, frames[0].data);
  second.close();
  manager.emitData(Buffer.from("dropped"));
  assert.equal(stream.queues.size, 0);
});

test("SessionStream.dispose disarms the timer and closes every subscriber", async () => {
  const timers = makeFakeTimers();
  const manager = makeFakeManager();
  const stream = makeStream({ manager, setTimer: timers.setTimer, clearTimer: timers.clearTimer });
  stream.start();
  stream.noteInput("x\n");
  manager.emitData(Buffer.from("y"));
  assert.equal(timers.count(), 1);
  const subscription = stream.subscribe();
  const ended = (async () => { const seen = []; for await (const frame of subscription.frames()) seen.push(frame); return seen; })();
  await flush();
  stream.dispose();
  assert.equal(timers.count(), 0);
  assert.equal(stream.queues.size, 0);
  assert.deepEqual(await ended, []);
});

test("SessionStream uses the documented default scrollback budget", () => {
  assert.equal(makeStream().log.maxBytes, DEFAULT_SCROLLBACK_BYTES);
});

// ---- TicketStore -----------------------------------------------------------

function makeTickets({ ttlMs = 1000, maxPerSession = MAX_TICKETS_PER_SESSION } = {}) {
  let clock = 0;
  let counter = 0;
  const store = new TicketStore({
    ttlMs,
    maxPerSession,
    now: () => clock,
    entropy: () => `ticket-${(counter += 1)}`,
  });
  return { store, advance: (ms) => { clock += ms; } };
}

test("TicketStore issues a ticket that verifies only for its own session", () => {
  const { store } = makeTickets();
  const issued = store.issue("sess-1");
  assert.equal(issued.ticket, "ticket-1");
  assert.equal(issued.sessionId, "sess-1");
  assert.equal(issued.expiresAt, 1000);
  assert.equal(store.verify("sess-1", issued.ticket), true);
  assert.equal(store.verify("sess-1", "ticket-2"), false);
  assert.equal(store.verify("sess-2", issued.ticket), false);
  assert.equal(store.verify("sess-1", ""), false);
  assert.equal(store.verify(null, issued.ticket), false);
});

test("TicketStore expires tickets by ttl and forgets the session", () => {
  const { store, advance } = makeTickets({ ttlMs: 100 });
  const issued = store.issue("sess-1");
  advance(100);
  assert.equal(store.verify("sess-1", issued.ticket), false);
  assert.equal(store.tickets.has("sess-1"), false);
  const again = store.issue("sess-1");
  assert.equal(store.verify("sess-1", again.ticket), true);
});

test("TicketStore keeps several live tickets per session so a second client does not evict the first", () => {
  const { store } = makeTickets();
  const a = store.issue("sess-1");
  const b = store.issue("sess-1");
  assert.notEqual(a.ticket, b.ticket);
  assert.equal(store.verify("sess-1", a.ticket), true);
  assert.equal(store.verify("sess-1", b.ticket), true);
  assert.equal(store.tickets.get("sess-1").size, 2);
});

test("TicketStore evicts the oldest ticket past the per-session ceiling", () => {
  const { store } = makeTickets({ maxPerSession: 2 });
  const a = store.issue("sess-1");
  const b = store.issue("sess-1");
  const c = store.issue("sess-1");
  assert.equal(store.verify("sess-1", a.ticket), false);
  assert.equal(store.verify("sess-1", b.ticket), true);
  assert.equal(store.verify("sess-1", c.ticket), true);
});

test("TicketStore.prune drops expired tickets and empty sessions", () => {
  const { store, advance } = makeTickets({ ttlMs: 50 });
  store.issue("sess-1");
  advance(10);
  store.issue("sess-2");
  advance(50);
  store.prune();
  assert.equal(store.tickets.has("sess-1"), false);
  assert.equal(store.tickets.has("sess-2"), false);
});

test("TicketStore requires an entropy source", () => {
  assert.throws(() => new TicketStore({}), /requires entropy/);
});

test("MAX_TICKETS_PER_SESSION is the default ceiling", () => {
  assert.equal(MAX_TICKETS_PER_SESSION, 8);
});
