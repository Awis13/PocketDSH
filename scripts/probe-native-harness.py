#!/usr/bin/env python3
"""Development-only transport probes. No real provider or project changes."""
import argparse
import http.server
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import tempfile
import threading
import time


def probe(binary, scenario):
    entered = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            if scenario == "http-error":
                self.send_response(503)
                self.end_headers()
                entered.set()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            entered.set()
            if scenario == "cancel":
                time.sleep(2)
                return
            frame = {"choices": [{"index": 0, "delta": {"content": "partial"}}]}
            self.wfile.write(("data: " + json.dumps(frame) + "\n\n").encode())
            self.wfile.flush()  # deliberately omit finish_reason and [DONE]

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="native-probe-") as directory:
            root = Path(directory)
            trace = root / "trace.json"
            env = dict(os.environ, HARNESS_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1", HARNESS_MODEL="fixture")
            env.pop("HARNESS_API_KEY", None)
            command = [str(binary), "--workspace", directory, "--store", str(root / "events.sqlite"),
                       "--session", "probe", "--prompt", "PRIVATE_PROBE_PROMPT", "--trace", str(trace)]
            process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert entered.wait(10), "Provider was not reached"
                if scenario == "cancel":
                    # Inspect while the request is still pending, then cancel.
                    before = json.loads(trace.read_text())
                    assert before["events"][0]["stage"] == "accepted"
                    assert all(x["stage"] != "completed" for x in before["events"])
                    process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=10)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
            report = json.loads(trace.read_text())
            last = report["events"][-1]
            assert process.returncode != 0, (scenario, stdout, stderr)
            assert last["stage"] == ("cancelled" if scenario == "cancel" else "failed"), (process.returncode, stdout, stderr, report)
            if scenario == "http-error":
                assert last["code"] == "HTTP_503", report
            assert "PRIVATE_PROBE_PROMPT" not in trace.read_text()
            with sqlite3.connect(root / "events.sqlite") as connection:
                events = [json.loads(row[0]) for row in connection.execute("SELECT body FROM events ORDER BY seq")]
            assert events[-1]["kind"] == "turn.ended", events
            if scenario == "cancel":
                assert events[-1]["detail"] == "cancelled", events
            return {"scenario": scenario, "stage": last["stage"], "code": last.get("code"), "elapsedMS": last["elapsedMS"]}
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("NativeHarness/.build/debug/harness"))
    args = parser.parse_args()
    for scenario in ["http-error", "truncated-stream", "cancel"]:
        print(json.dumps(probe(args.binary.resolve(), scenario)), flush=True)
