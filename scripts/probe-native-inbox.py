#!/usr/bin/env python3
"""Kill a real CLI process with pending inbox entries, then resume its database."""
import argparse
import http.server
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading
import time


def main(binary):
    entered = threading.Event()
    release = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            entered.set()
            release.wait(10)
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

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="inbox-probe-") as directory:
            root = Path(directory)
            db = root / "history.sqlite"
            env = dict(os.environ, HARNESS_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1", HARNESS_MODEL="fixture")
            env.pop("HARNESS_API_KEY", None)
            base = [str(binary), "--workspace", directory, "--store", str(db), "--session", "crash"]
            process = subprocess.Popen(base + ["--interactive", "--prompt", "initial"], env=env,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert entered.wait(10), "First request did not start"
                for command in [{"op": "queue", "id": "q1", "prompt": "queued"},
                                {"op": "steer", "id": "s1", "prompt": "steering"}]:
                    process.stdin.write(json.dumps(command) + "\n")
                process.stdin.flush()
                for _ in range(200):
                    with sqlite3.connect(db) as connection:
                        count = connection.execute("SELECT count(*) FROM commands WHERE state='pending'").fetchone()[0]
                    if count == 2:
                        break
                    time.sleep(0.01)
                assert count == 2, "Commands were not durably admitted"
                process.kill()
                process.communicate(timeout=5)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
                release.set()
            resumed = subprocess.run(base + ["--resume"], env=env, capture_output=True, text=True, timeout=10)
            assert resumed.returncode == 0, resumed.stderr
            with sqlite3.connect(db) as connection:
                rows = connection.execute("SELECT id,state FROM commands ORDER BY seq").fetchall()
                events = [json.loads(row[0]) for row in connection.execute("SELECT body FROM events ORDER BY seq")]
            assert all(state == "consumed" for _, state in rows), rows
            for identity in ["q1", "s1"]:
                assert sum(event.get("commandID") == identity and "message" in event for event in events) == 1, events
            endings = [event.get("detail") for event in events if event["kind"] == "turn.ended"]
            assert endings == ["interrupted", "completed"], endings
            empty = subprocess.run(base + ["--resume"], env=env, capture_output=True, text=True, timeout=10)
            assert empty.returncode == 0, empty.stderr
            with sqlite3.connect(db) as connection:
                after = connection.execute("SELECT count(*) FROM events").fetchone()[0]
            assert after == len(events), "Empty resume replayed consumed work"
            print(json.dumps({"crashResume": "passed", "turnEndings": endings, "queuedAndSteeredMessages": "once each", "emptyResume": "no replay"}))
    finally:
        release.set()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("NativeHarness/.build/debug/harness"))
    main(parser.parse_args().binary.resolve())
