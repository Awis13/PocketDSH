// Pocket DSH — Pocket Terminal core tests (commit C1 of DSH-TERMINAL).
//
// Exercises the pure core with an injectable fake PTY (no real spawn). The
// fake ctx mirrors how session.append drives the synchronous internal/dispatch
// observers, so the sandbox-mode fence is tested exactly as the live path runs
// it. Run: node --test plugins/dsh-pocket-terminal/test/*.test.js
import test from "node:test";
import assert from "node:assert/strict";
import { TerminalManager, installSandboxModeFence, SANDBOX_MODES } from "../core.js";

// ---- fakes -----------------------------------------------------------------

// Minimal async-iterable source: push() feeds the for-await, end() closes it.
function makeAsyncSource() {
  const queue = [];
  const waiters = [];
  let ended = false;
  const it = {
    next() {
      if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
      if (ended) return Promise.resolve({ value: undefined, done: true });
      return new Promise((res) => waiters.push(res));
    },
    return() {
      ended = true;
      while (waiters.length) waiters.shift()({ value: undefined, done: true });
      return Promise.resolve({ value: undefined, done: true });
    },
  };
  return {
    source: { [Symbol.asyncIterator]: () => it },
    push(v) { if (ended) return; if (waiters.length) waiters.shift()({ value: v, done: false }); else queue.push(v); },
    end() { ended = true; while (waiters.length) waiters.shift()({ value: undefined, done: true }); },
  };
}

// Fake PTY in the core's RawPty shape; records every call for assertions.
function makeFakePty() {
  const out = makeAsyncSource();
  let doneResolve, doneReject;
  const done = new Promise((res, rej) => { doneResolve = res; doneReject = rej; });
  const pty = {
    pid: 4242,
    output: out.source,
    done,
    written: [],
    signals: [],
    resizes: [],
    terminateCount: 0,
    async write(d) { pty.written.push(d); },
    async signal(sig) { pty.signals.push(sig); return pty.pid; },
    resize(cols, rows) { pty.resizes.push([cols, rows]); },
    async terminate() { pty.terminateCount++; },
    pushData(v) { out.push(v); },
    endOutput() { out.end(); },
    exit(outcome) { out.end(); doneResolve(outcome); },
    fail(err) { out.end(); doneReject(err); },
  };
  return pty;
}

// Fake cordis context: records internal/dispatch handlers and lets the test
// drive them the way session.append does (synchronously).
function makeFakeCtx() {
  const handlers = new Map();
  return {
    on(type, handler) { if (!handlers.has(type)) handlers.set(type, new Set()); handlers.get(type).add(handler); },
    off(type, handler) { handlers.get(type)?.delete(handler); },
    dispatch(eventName, args) {
      const set = handlers.get("internal/dispatch");
      if (!set) return;
      for (const h of [...set]) h("dispatch", eventName, args);
    },
    handlerCount(type) { return handlers.get(type)?.size ?? 0; },
  };
}

const session = { id: "sess-1" };
const SHELL = ["/bin/bash", "-l"];
const WORKSPACE = "/ws";
const modeEvent = (mode) => ({ type: "sandbox/mode", seq: 1, time: 0, data: { mode } });

function makeManager({ mode = "workspace-write", pty } = {}) {
  const ctx = makeFakeCtx();
  const captured = { spec: null, pty };
  const manager = new TerminalManager({
    session,
    ctx,
    sandboxPolicy: { resolve: () => ({ mode, workspaceRoot: WORKSPACE }) },
    sandbox: { confine: (argv, policy) => ({ argv: ["C:" + policy.mode, ...argv] }) },
    spawnTerminal: async (spec) => { captured.spec = spec; return pty ?? makeFakePty(); },
    shellArgv: SHELL,
    rows: 24,
    cols: 80,
    graceMs: 5000,
  });
  return { manager, ctx, captured };
}

async function flush(times = 30) { for (let i = 0; i < times; i++) await new Promise((r) => setImmediate(r)); }

// ---- spawn + confinement ---------------------------------------------------

test("spawn resolves the policy, confines argv, and passes PTY geometry", async (t) => {
  const { manager, captured } = makeManager({ mode: "workspace-write" });
  t.after(() => manager.dispose());
  await manager.spawn();
  assert.equal(captured.spec.cwd, WORKSPACE);
  assert.equal(captured.spec.rows, 24);
  assert.equal(captured.spec.cols, 80);
  assert.equal(captured.spec.graceMs, 5000);
  assert.deepEqual(captured.spec.argv, ["C:workspace-write", ...SHELL]);
  assert.equal(manager.live, true);
  assert.equal(manager.pid, 4242);
});

for (const mode of ["read-only", "workspace-write", "danger-full-access"]) {
  test("confine by mode: " + mode, async (t) => {
    const { manager, captured } = makeManager({ mode });
    t.after(() => manager.dispose());
    await manager.spawn();
    if (mode === "danger-full-access") {
      assert.deepEqual(captured.spec.argv, SHELL, "danger-full-access passes the argv through unwrapped");
    } else {
      assert.deepEqual(captured.spec.argv, ["C:" + mode, ...SHELL], mode + " wraps the argv via sandbox.confine");
    }
  });
}

test("confined mode without a sandbox provider throws", async () => {
  const { manager } = makeManager({ mode: "read-only" });
  manager.sandbox = null;
  await assert.rejects(() => manager.spawn(), /requires a sandbox provider/);
  assert.equal(manager.live, false);
});

// ---- write / read ----------------------------------------------------------

test("write requires the input writer and reaches the PTY", async (t) => {
  const { manager } = makeManager({});
  t.after(() => { manager.dispose(); });
  await manager.spawn();
  await assert.rejects(() => manager.write("ls\n"), /no input owner/);
  manager.acquireWriter("client-a");
  await manager.write("ls\n");
  await manager.write("pwd\n");
});

test("write is forwarded to the PTY in order", async (t) => {
  const pty = makeFakePty();
  const { manager } = makeManager({ pty });
  t.after(() => { manager.dispose(); pty.endOutput(); });
  await manager.spawn();
  manager.acquireWriter("client-a");
  await manager.write("ls\n");
  await manager.write("pwd\n");
  assert.deepEqual(pty.written, ["ls\n", "pwd\n"]);
  assert.equal(manager.writer, "client-a");
});

test("reader observes PTY output", async (t) => {
  const pty = makeFakePty();
  const { manager } = makeManager({ pty });
  t.after(() => { manager.dispose(); pty.endOutput(); });
  const received = [];
  manager.onData((chunk) => { received.push(String(chunk)); });
  await manager.spawn();
  pty.pushData("total 0\n");
  pty.pushData("foo.txt\n");
  await flush();
  assert.equal(received.join(""), "total 0\nfoo.txt\n");
});

// ---- resize (TIOCSWINSZ path) ---------------------------------------------

test("resize is forwarded to the PTY as (cols, rows)", async (t) => {
  const pty = makeFakePty();
  const { manager } = makeManager({ pty });
  t.after(() => { manager.dispose(); pty.endOutput(); });
  await manager.spawn();
  await manager.resize(120, 40);
  assert.deepEqual(pty.resizes, [[120, 40]]);
});

test("resize before spawn throws", async () => {
  const { manager } = makeManager({});
  await assert.rejects(() => manager.resize(10, 10), /no terminal spawned/);
  manager.dispose();
});

// ---- signals ----------------------------------------------------------------

test("signal is forwarded to the PTY and requires a writer", async (t) => {
  const pty = makeFakePty();
  const { manager } = makeManager({ pty });
  t.after(() => { manager.dispose(); pty.endOutput(); });
  await manager.spawn();
  await assert.rejects(() => manager.signal("SIGINT"), /no input owner/);
  manager.acquireWriter("client-a");
  await manager.signal("SIGINT");
  assert.deepEqual(pty.signals, ["SIGINT"]);
});

// ---- single writer ---------------------------------------------------------

test("second writer is rejected, owner re-acquire is idempotent", async (t) => {
  const { manager } = makeManager({});
  t.after(() => { manager.dispose(); });
  await manager.spawn();
  manager.acquireWriter("client-a");
  assert.throws(() => manager.acquireWriter("client-b"), /second writer rejected/);
  assert.doesNotThrow(() => manager.acquireWriter("client-a"));
  assert.equal(manager.writer, "client-a");
  manager.releaseWriter("client-a");
  assert.equal(manager.writer, null);
});

// ---- exit + cleanup --------------------------------------------------------

test("process exit settles the PTY, releases the writer, disposes it, and unfreezes the mode", async (t) => {
  const pty = makeFakePty();
  const { manager, ctx } = makeManager({ pty, mode: "workspace-write" });
  t.after(() => { manager.dispose(); });
  let exitOutcome = null;
  manager.onExit((o) => { exitOutcome = o; });
  await manager.spawn();
  manager.acquireWriter("client-a");

  // While live, a mode change to a different mode is blocked.
  assert.throws(() => ctx.dispatch("session/event", [session, modeEvent("danger-full-access")]));

  // The process exits 0.
  pty.exit({ exitCode: 0, signal: null });
  await flush();

  assert.deepEqual(exitOutcome, { exitCode: 0, signal: null });
  assert.equal(pty.terminateCount, 1, "PTY disposed on exit");
  assert.equal(manager.writer, null, "writer released on exit");
  assert.equal(manager.live, false, "no longer live after exit");
  // Mode is now free to change (fence inactive).
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, modeEvent("danger-full-access")]));
});

test("abnormal exit (done rejects) settles and reports the error", async (t) => {
  const pty = makeFakePty();
  const { manager } = makeManager({ pty });
  t.after(() => { manager.dispose(); });
  let exitOutcome = null;
  manager.onExit((o) => { exitOutcome = o; });
  await manager.spawn();
  pty.fail(new Error("boom"));
  await flush();
  assert.equal(exitOutcome.exitCode, null);
  assert.equal(exitOutcome.signal, null);
  assert.match(exitOutcome.error.message, /boom/);
  assert.equal(manager.live, false);
});

// ---- sandbox-mode fence ----------------------------------------------------

test("fence blocks a different mode while a PTY is live, allows the frozen mode", async (t) => {
  const pty = makeFakePty();
  const { manager, ctx } = makeManager({ pty, mode: "read-only" });
  t.after(() => { manager.dispose(); pty.endOutput(); });
  await manager.spawn();
  assert.equal(manager.frozenMode, "read-only");
  // no-op re-set of the frozen mode → allowed
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, modeEvent("read-only")]));
  // a different mode → blocked
  assert.throws(() => ctx.dispatch("session/event", [session, modeEvent("workspace-write")]), /cannot change sandbox mode/);
  // an unrelated session/event is untouched
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, { type: "chat/message", seq: 2, time: 0, data: {} }]));
});

test("fence is inert before spawn and after exit", async (t) => {
  const pty = makeFakePty();
  const { manager, ctx } = makeManager({ pty, mode: "workspace-write" });
  t.after(() => { manager.dispose(); pty.endOutput(); });
  // Before spawn there is no live PTY → allowed.
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, modeEvent("danger-full-access")]));
  await manager.spawn();
  assert.throws(() => ctx.dispatch("session/event", [session, modeEvent("danger-full-access")]));
  pty.exit({ exitCode: 0, signal: null });
  await flush();
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, modeEvent("danger-full-access")]));
});

test("installSandboxModeFence standalone: no live PTY → allowed", () => {
  const ctx = makeFakeCtx();
  const dispose = installSandboxModeFence(ctx, {
    session,
    isLive: () => false,
    frozenMode: () => "read-only",
  });
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, modeEvent("danger-full-access")]));
  dispose();
});

test("installSandboxModeFence standalone: live + different mode → throws", () => {
  const ctx = makeFakeCtx();
  installSandboxModeFence(ctx, {
    session,
    isLive: () => true,
    frozenMode: () => "read-only",
  });
  assert.throws(() => ctx.dispatch("session/event", [session, modeEvent("workspace-write")]));
  assert.doesNotThrow(() => ctx.dispatch("session/event", [session, modeEvent("read-only")]));
});

// ---- sanity ----------------------------------------------------------------

test("SANDBOX_MODES is the documented escalation set", () => {
  assert.deepEqual(SANDBOX_MODES, ["read-only", "workspace-write", "danger-full-access"]);
});
