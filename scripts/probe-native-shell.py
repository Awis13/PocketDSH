#!/usr/bin/env python3
"""Exercise real CLI approval/control and OS commands against a loopback model fixture."""
import argparse
import base64
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


def run(binary, mode):
    with tempfile.TemporaryDirectory(prefix="native-shell-") as directory:
        root = Path(directory)
        requests = []
        command = "printf STREAM_OK; sleep 15" if mode == "cancel" else "printf approved > marker; printf STREAM_OK; printf ERROR_STREAM >&2"

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(body)
                has_result = any(m["role"] == "tool" for m in body["messages"])
                if has_result or mode == "context":
                    delta = {"content": "DONE"}
                    reason = "stop"
                else:
                    delta = {"tool_calls": [{"index": 0, "id": "shell-1", "type": "function", "function": {"name": "shell", "arguments": json.dumps({"command": command})}}]}
                    reason = "tool_calls"
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                chunk = {"choices": [{"delta": delta, "finish_reason": reason}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = dict(os.environ, HARNESS_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1", HARNESS_MODEL="fixture")
        args = [binary, "--workspace", str(root), "--store", str(root / "events.db"), "--session", "probe", "--interactive"]
        if mode != "context":
            args += ["--prompt", "Run the shell fixture."]
        process = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        lines = queue.Queue()
        threading.Thread(target=lambda: [lines.put(s) for s in process.stderr], daemon=True).start()
        stdout = []
        threading.Thread(target=lambda: stdout.append(process.stdout.read()), daemon=True).start()
        streamed = b""
        approved = False
        sent_context = False
        closed = False

        def send(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()

        if mode == "context":
            send({"op": "shell", "command": "printf HUMAN_CONTEXT"})
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if process.poll() is not None and lines.empty():
                    break
                try:
                    line = lines.get(timeout=0.1)
                except queue.Empty:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    event = {}
                if event.get("control") == "approval":
                    assert not (root / "marker").exists(), "Effect before approval"
                    if mode == "disconnect":
                        process.stdin.close(); closed = True
                    else:
                        send({"op": "approval", "id": event["request"]["id"], "allow": mode != "deny"})
                        approved = mode != "deny"
                if event.get("control") == "shellOutput":
                    streamed += base64.b64decode(event["output"]["bytes"])
                    if mode == "cancel" and b"STREAM_OK" in streamed:
                        send({"op": "cancel"})
                if event.get("control") == "shellCompleted" and mode == "context":
                    assert not requests, "Human shell leaked to model"
                    block = event["block"]
                    send({"op": "context", "blockID": block["id"]})
                    send({"op": "send-context", "blockID": block["id"], "id": "context-1", "prompt": "Explain this output"})
                    sent_context = True
                if ("[turnCompleted " in line or "[cancelled " in line) and not closed:
                    process.stdin.close(); closed = True
            code = process.wait(timeout=3)
            events = [json.loads(r[0]) for r in sqlite3.connect(root / "events.db").execute("SELECT body FROM events ORDER BY seq")]
            kinds = [e["kind"] for e in events]
            if mode in ("deny", "disconnect"):
                assert not (root / "marker").exists()
                assert "approval.denied" in kinds and "shell.started" not in kinds
            if mode == "allow":
                assert approved and (root / "marker").read_text() == "approved"
                assert b"STREAM_OK" in streamed and b"ERROR_STREAM" in streamed
                assert "approval.allowed" in kinds and "shell.completed" in kinds
            if mode == "cancel":
                block = json.loads(next(e["detail"] for e in events if e["kind"] == "shell.completed"))
                assert block["outcome"] == "cancelled"
                assert code == 1
            else:
                assert code == 0, code
            if mode == "context":
                assert sent_context and len(requests) == 1
                assert "HUMAN_CONTEXT" in requests[0]["messages"][-1]["content"]
            return {"scenario": mode, "status": "passed", "providerRequests": len(requests), "streamedBytes": len(streamed)}
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            server.shutdown(); server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    args = parser.parse_args()
    for mode in ("allow", "deny", "disconnect", "cancel", "context"):
        print(json.dumps(run(str(Path(args.binary).resolve()), mode)), flush=True)
