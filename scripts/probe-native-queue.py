#!/usr/bin/env python3
"""Kill a real CLI process with an edited/steered/removed pending queue, then
reopen the database and prove pending work is preserved, runs once and only on
an explicit resume, and that already-consumed IDs are rejected."""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import sqlite3
import subprocess
import tempfile
import threading
import time


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


def main(binary):
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("NativeHarness/.build/debug/harness"))
    main(parser.parse_args().binary.resolve())
