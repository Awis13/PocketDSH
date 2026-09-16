#!/usr/bin/env python3
"""Two queue-control probes.

`interactive_phase` kills a real CLI process with an edited/steered/removed
pending queue, reopens the database and proves pending work is preserved, runs
once and only on an explicit resume, and that already-consumed IDs are rejected.

`host_phase` starts the real `harness --host` WebSocket server against an
isolated temp workspace/store and a local fixture provider, drives edit/remove/
steer through `Tests/NativeQueueReceiptChecks.swift`, restarts the host on the
same store, and proves durable queue-control receipts replay without mutation."""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import secrets
import shutil
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid


class Cli:
    def __init__(self, base, env):
        self.process = subprocess.Popen(base, env=env, stdin=subprocess.PIPE,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.replies = queue.Queue()
        self.reader = threading.Thread(target=self._read, args=(self.process.stderr,), daemon=True)
        self.reader.start()

    def _read(self, stream):
        for raw in iter(stream.readline, ""):
            raw = raw.strip()
            if not raw:
                continue
            try:
                value = json.loads(raw)
            except ValueError:
                continue
            if isinstance(value, dict) and "control" in value:
                self.replies.put(value)

    def send(self, **command):
        self.process.stdin.write(json.dumps(command) + "\n")
        self.process.stdin.flush()

    def wait(self, controls, timeout=20):
        if isinstance(controls, str):
            controls = {controls}
        seen = []
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                value = self.replies.get(timeout=remaining)
            except queue.Empty:
                break
            seen.append(value.get("control"))
            if value.get("control") in controls:
                return value
        raise AssertionError(f"Expected {controls}, saw {seen}")

    def stop(self):
        try:
            if self.process.stdin:
                self.process.stdin.close()
            self.process.wait(timeout=10)
        except (BrokenPipeError, subprocess.TimeoutExpired):
            self.process.kill()
            self.process.wait()


def sqlite_pending(db):
    with sqlite3.connect(db) as connection:
        return connection.execute(
            "SELECT id, prompt, mode, state FROM commands ORDER BY seq").fetchall()


def sqlite_messages(db):
    with sqlite3.connect(db) as connection:
        rows = connection.execute("SELECT body FROM events ORDER BY seq").fetchall()
    return [json.loads(row[0]) for row in rows]


def interactive_phase(binary):
    entered = threading.Event()
    release = threading.Event()
    state = {"hold": True}

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if state["hold"]:
                entered.set()
                release.wait(15)
            frame = {"choices": [{"index": 0, "delta": {"content": "fixture complete"}, "finish_reason": "stop"}]}
            body = ("data: " + json.dumps(frame) + "\n\ndata: [DONE]\n\n").encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="queue-probe-") as directory:
            db = Path(directory) / "history.sqlite"
            env = dict(os.environ, HARNESS_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1", HARNESS_MODEL="fixture")
            env.pop("HARNESS_API_KEY", None)
            base = [str(binary), "--workspace", directory, "--store", str(db), "--session", "queue"]
            cli = Cli(base + ["--interactive", "--prompt", "initial"], env)
            try:
                assert entered.wait(15), "First request did not start"
                cli.send(op="queue", id="q1", prompt="queued one")
                cli.send(op="queue", id="q2", prompt="edit me")
                cli.send(op="queue", id="q3", prompt="remove me")
                cli.send(op="queue", id="q4", prompt="steer me")
                cli.send(op="steer", id="s1", prompt="inline steer")
                assert cli.wait("accepted")["receipt"]["id"] == "q1"
                cli.send(op="edit", id="q2", prompt="edited prompt")
                cli.send(op="remove", id="q3")
                cli.send(op="steerPending", id="q4")
                assert cli.wait("edited")["removed"] is True
                assert cli.wait("removed")["removed"] is True
                assert cli.wait("steered")["removed"] is True
                cli.send(op="pending")
                snapshot = cli.wait("pending")["queue"]
                assert [item["id"] for item in snapshot["items"]] == ["q1", "q2", "q4", "s1"], snapshot
                assert [item["placement"] for item in snapshot["items"]] == ["queued", "queued", "steering", "steering"], snapshot
                assert snapshot["items"][1]["preview"] == "edited prompt", snapshot
                assert snapshot["omitted"] == 0
                cli.process.kill()
                cli.process.communicate(timeout=5)
            finally:
                if cli.process.poll() is None:
                    cli.process.kill()
                    cli.process.communicate()
                release.set()

            rows = dict((row[0], (row[1], row[2], row[3])) for row in sqlite_pending(db))
            assert rows["q2"][0] == "edited prompt", rows
            assert rows["q3"][2] == "cancelled", rows
            assert rows["q4"][1] == "steer" and rows["s1"][1] == "steer", rows
            assert [row[0] for row in sqlite_pending(db) if row[3] == "pending"] == ["q1", "q2", "q4", "s1"], rows

            state["hold"] = False
            reopened = Cli(base + ["--interactive"], env)
            try:
                time.sleep(0.5)
                reopened.send(op="pending")
                preserved = reopened.wait("pending")["queue"]
                assert [item["id"] for item in preserved["items"]] == ["q1", "q2", "q4", "s1"], preserved
                # Merely reopening the same session must not run preserved work.
                assert not sqlite_messages(db) or all(
                    event.get("commandID") not in {"q1", "q2", "q4", "s1"}
                    for event in sqlite_messages(db) if event.get("message")), "Reopen auto-ran pending work"

                reopened.send(op="resume")
                assert reopened.wait("resumed")["control"] == "resumed"
                deadline = time.monotonic() + 20
                idle = None
                while time.monotonic() < deadline:
                    reopened.send(op="status")
                    idle = reopened.wait("status")["status"]
                    if idle["running"] is False and idle["pendingCount"] == 0:
                        break
                    time.sleep(0.1)
                assert idle and idle["running"] is False and idle["pendingCount"] == 0, idle

                messages = sqlite_messages(db)
                for identity in ["q1", "q2", "q4", "s1"]:
                    count = sum(1 for event in messages
                                if event.get("commandID") == identity and event.get("message"))
                    assert count == 1, (identity, count)
                states = {row[0]: row[3] for row in sqlite_pending(db)}
                assert states["q1"] == states["q2"] == states["q4"] == states["s1"] == "consumed", states
                assert states["q3"] == "cancelled", states

                # A consumed ID is not selectable any more.
                reopened.send(op="edit", id="q2", prompt="too late")
                assert reopened.wait("edited")["removed"] is False
                reopened.send(op="remove", id="q2")
                assert reopened.wait("removed")["removed"] is False
                # Steering while idle is refused, not silently queued.
                reopened.send(op="steerPending", id="q1")
                rejected = reopened.wait("rejected")
                assert "only available while a turn is running" in rejected["error"], rejected
            finally:
                reopened.stop()
            print(json.dumps({
                "modeRoundTrip": "queue and steer placement confirmed",
                "editRemoveSteerByID": "applied while streaming",
                "alreadyConsumedID": "rejected",
                "restartPreservesPending": "no auto-run, ran once on explicit resume",
                "doubleConsume": "none",
            }))
    finally:
        release.set()
        server.shutdown()
        server.server_close()


def verify_queue_db(store, config, phase, previous=None):
    """Independent storage checks that the wire driver cannot make itself."""
    canary = config["canary"]
    with sqlite3.connect(store) as connection:
        tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        assert "queue_operations" in tables, f"[{phase}] durable queue_operations table is missing"
        rows = connection.execute("SELECT id, session, fingerprint, receipt FROM queue_operations").fetchall()
        assert rows, f"[{phase}] no durable queue receipts were written"
        for request_id, _session, fingerprint, receipt in rows:
            # The durable row may never carry the plaintext edit prompt.
            assert len(fingerprint) == 64, (request_id, fingerprint)
            assert canary not in fingerprint and canary not in receipt, (request_id, fingerprint, receipt)
            assert receipt == "accepted" or receipt.startswith("rejected:"), receipt
        s1_receipts = {r[0]: r[1] for r in connection.execute(
            "SELECT id, fingerprint FROM queue_operations WHERE session=?", (config["s1"],))}
        s2_receipts = {r[0]: r[1] for r in connection.execute(
            "SELECT id, fingerprint FROM queue_operations WHERE session=?", (config["s2"],))}
        assert config["reqEditA"] in s1_receipts and config["reqEditA"] in s2_receipts, (s1_receipts, s2_receipts)
        assert s1_receipts[config["reqEditA"]] != s2_receipts[config["reqEditA"]], \
            "the same request ID must have independent receipts per session"
        prompt = connection.execute("SELECT prompt FROM commands WHERE session=? AND id=?",
                                    (config["s1"], config["itemEdit"])).fetchone()
        assert prompt and prompt[0] == config["editB"], (phase, prompt)

        def count(kind):
            return connection.execute("SELECT COUNT(*) FROM events WHERE session=? AND body LIKE ?",
                                      (config["s1"], "%" + kind + "%")).fetchone()[0]

        summary = {"receipts": len(rows), "edited": count("inbox.edited"),
                   "cancelled": count("inbox.cancelled"), "steered": count("inbox.steered")}
    # Retries must neither re-run the mutation nor duplicate its audit event.
    assert summary["edited"] == 2, summary
    assert summary["cancelled"] == 1, summary
    assert summary["steered"] == 1, summary
    if previous is not None:
        assert summary == previous, (previous, summary)
    return summary


def host_phase(binary, client):
    released = threading.Event()
    state = {"hold": True}

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if state["hold"]:
                released.wait(120)
            frame = {"choices": [{"index": 0, "delta": {"content": "fixture complete"}, "finish_reason": "stop"}]}
            body = ("data: " + json.dumps(frame) + "\n\ndata: [DONE]\n\n").encode()
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    workdir = tempfile.mkdtemp(prefix="queue-receipt-")
    root = Path(workdir)
    host = None
    try:
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        token = secrets.token_hex(32)
        canary = "PLAINTEXT_CANARY_" + secrets.token_hex(8)
        config = {
            "endpoint": f"ws://127.0.0.1:{port}", "token": token, "canary": canary,
            "s1": str(uuid.uuid4()), "s2": str(uuid.uuid4()),
            "editA": canary + "-A", "editB": canary + "-B",
            "itemEdit": "q-edit", "itemRemove": "q-remove", "itemSteer": "q-steer",
            "itemMissing": "q-missing", "itemS2": "q-s2",
            "reqPrompt": "p-hold", "reqEditA": "r-edit-a", "reqEditB": "r-edit-b",
            "reqRemove": "r-remove", "reqSteer": "r-steer", "reqReject": "r-reject",
        }
        connection_file = root / "connection.json"
        connection_file.write_text(json.dumps(config))
        connection_file.chmod(0o600)
        env = dict(os.environ,
                   HARNESS_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1",
                   HARNESS_MODEL="fixture", HARNESS_HOST_PORT=str(port), HARNESS_HOST_TOKEN=token)
        for key in ["HARNESS_API_KEY", "HARNESS_PROVIDER_PROFILE", "HARNESS_CONTEXT_TOKENS",
                    "HARNESS_INCLUDE_USAGE", "HARNESS_DISABLE_THINKING"]:
            env.pop(key, None)
        store = root / "events.sqlite"

        def start():
            log = (root / "host.log").open("ab")
            process = subprocess.Popen(
                [str(binary), "--host", "--workspace", workdir, "--store", str(store)],
                env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError("Isolated host failed to start: " + str(root / "host.log"))
                try:
                    with socket.create_connection(("127.0.0.1", port), .1):
                        return process
                except OSError:
                    time.sleep(.05)
            process.kill()
            process.wait()
            raise RuntimeError("Isolated host timed out")

        host = start()
        subprocess.run([str(client), workdir, "live"], check=True, timeout=60)
        live = verify_queue_db(store, config, "live")
        host.terminate()
        host.wait(timeout=10)
        host = None
        state["hold"] = False
        released.set()
        host = start()
        subprocess.run([str(client), workdir, "replay"], check=True, timeout=60)
        verify_queue_db(store, config, "replay", previous=live)
        print(json.dumps({
            "hostRestartReplay": "exact edit/remove/steer receipts replayed, B preserved",
            "changedFingerprint": "refused with no mutation",
            "auditEvents": "not duplicated across restart",
            "sessionIsolation": "independent receipts per session",
            "persistedFingerprint": "digest only, no plaintext prompt",
        }))
    finally:
        released.set()
        if host and host.poll() is None:
            host.terminate()
            try:
                host.wait(timeout=10)
            except subprocess.TimeoutExpired:
                host.kill()
                host.wait()
        server.shutdown()
        server.server_close()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("NativeHarness/.build/debug/harness"))
    parser.add_argument("--client", type=Path, default=Path(".build/checks/native-queue-receipt"))
    parser.add_argument("--skip-interactive", action="store_true")
    args = parser.parse_args()
    if not args.skip_interactive:
        interactive_phase(args.binary.resolve())
    host_phase(args.binary.resolve(), args.client.resolve())
