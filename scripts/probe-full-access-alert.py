#!/usr/bin/env python3
"""Controlled DSH transport for the Full access confirmation UI checks.

One HTTP server answers both the RPC surface and the `$events` websocket (no
third-party packages), so the app can connect, list one stub session, serve a
command catalog and hand `commands/execute` calls to this probe instead of a
live Host. The user's sessions, credentials and permission policy are never
touched.

Control surface (the UI checks use it):
  GET /__review3/calls     -> {"calls": [...]}  every commands/execute received
  GET /__review3/requests  -> {"requests": [...]} every RPC received
  GET /__review3/reset     -> {"ok": true}      clears the recorded state
  GET /__review3/approval  -> pushes one approval/request over $events
  GET /__review3/drop      -> drops every $events connection

Usage: python3 scripts/probe-full-access-alert.py [port]   (default 8791)
It is a test transport: it serves one stub session, applies no policy and holds
no credentials.
"""
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8791
SESSION_ID = "session-review3-stub"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

CALLS = []
LOCK = threading.Lock()
WS_WRITERS = []
WS_SOCKETS = []

CATALOG = [
    {"name": "permission", "description": "Switch the permission preset (sandbox mode + approval policy)",
     "input": {"hint": "<preset>"}},
    {"name": "compact", "description": "Compact the session context",
     "input": {"hint": "compact [reason]", "attachments": True}},
    {"name": "goal", "description": "Manage the session goal"},
    {"name": "help", "description": "Show available commands"},
]

SECOND_ID = "session-review3-stub-2"
SECOND = {
    "sessionId": SECOND_ID,
    "cwd": "/tmp/review3-workspace-2",
    "running": False,
    "updatedAt": 1757680100000,
    "origin": "user",
    "projections": {"values": {"title": "Review 3 second session"}},
}

SESSION = {
    "sessionId": SESSION_ID,
    "cwd": "/tmp/review3-workspace",
    "running": False,
    "updatedAt": 1757680000000,
    "origin": "user",
    "projections": {"values": {"title": "Review 3 stub session"}},
}


REQUESTS = []


def note(method, args):
    with LOCK:
        REQUESTS.append({"method": method, "line": args.get("line"),
                         "agentId": args.get("agentId"), "sessionId": args.get("sessionId")})


def rpc_value(method, args):
    note(method, args)
    if method == "session/list":
        return {"items": [SESSION, SECOND]}
    if method == "session/modelCatalog":
        return {"default": {"provider": "stub", "model": "stub-model"}, "groups": []}
    if method == "commands/list":
        return CATALOG
    if method == "commands/execute":
        with LOCK:
            CALLS.append({"method": method, "line": args.get("line", ""),
                          "agentId": args.get("agentId", ""),
                          "attachments": len(args.get("submittedAttachments", []) or [])})
        return {"commandId": "stub-command-1",
                "result": {"kind": "success", "text": "preset danger-full-access"}}
    if method == "session/create":
        return {"sessionId": SESSION_ID}
    if method == "session/page":
        return {"records": [], "hasMore": False}
    return None


def read_exactly(stream, count):
    data = b""
    while len(data) < count:
        chunk = stream.read(count - len(data))
        if not chunk:
            return None
        data += chunk
    return data


def read_frame(stream):
    header = read_exactly(stream, 2)
    if header is None:
        return None
    opcode = header[0] & 0x0F
    masked = header[1] & 0x80
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", read_exactly(stream, 2))[0]
    elif length == 127:
        length = struct.unpack(">Q", read_exactly(stream, 8))[0]
    mask = read_exactly(stream, 4) if masked else b"\x00\x00\x00\x00"
    payload = read_exactly(stream, length) if length else b""
    if payload is None:
        return None
    return bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload)), opcode


def send_text(stream, text):
    payload = text.encode()
    header = bytes([0x81])
    if len(payload) < 126:
        header += bytes([len(payload)])
    elif len(payload) < 65536:
        header += bytes([126]) + struct.pack(">H", len(payload))
    else:
        header += bytes([127]) + struct.pack(">Q", len(payload))
    stream.write(header + payload)
    stream.flush()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _send(self, code, body=b"", headers=None):
        self.send_response(code)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        if (self.headers.get("Upgrade") or "").lower() == "websocket":
            return self._websocket()
        path = self.path.split("?")[0]
        if path == "/__review3/calls":
            with LOCK:
                body = json.dumps({"calls": list(CALLS)}).encode()
            self._send(200, body, {"Content-Type": "application/json"})
            return
        if path == "/__review3/drop":
            with LOCK:
                sockets = list(WS_SOCKETS)
            for sock in sockets:
                try:
                    sock.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
                try:
                    sock.close()
                except OSError:
                    pass
            self._send(200, json.dumps({"ok": True, "dropped": len(sockets)}).encode(), {"Content-Type": "application/json"})
            return
        if path == "/__review3/approval":
            frame = json.dumps({
                "type": "item", "streamId": "$events",
                "value": {"type": "waterfall", "event": "approval/request", "eventId": "stub-approval-1",
                          "agentId": SESSION_ID, "clientId": "stub-client",
                          "request": {"toolName": "bash", "reason": "Review 3 probe: list the workspace",
                                      "callId": "stub-call-1"}},
            })
            with LOCK:
                writers = list(WS_WRITERS)
            for writer in writers:
                try:
                    send_text(writer, frame)
                except OSError:
                    pass
            self._send(200, json.dumps({"ok": True, "writers": len(writers)}).encode(), {"Content-Type": "application/json"})
            return
        if path == "/__review3/requests":
            with LOCK:
                body = json.dumps({"requests": list(REQUESTS)}).encode()
            self._send(200, body, {"Content-Type": "application/json"})
            return
        if path == "/__review3/reset":
            with LOCK:
                CALLS.clear()
                REQUESTS.clear()
            self._send(200, b'{"ok":true}', {"Content-Type": "application/json"})
            return
        # The login route: any token is accepted, and the cookie is what the
        # client keeps. No credential of any kind is involved.
        self._send(302, b"", {"Set-Cookie": "dsh_stub=1; Path=/", "Location": "/"})

    def _websocket(self):
        print("WS upgrade request", self.path, flush=True)
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()
        reader, writer = self.rfile, self.wfile
        with LOCK:
            WS_WRITERS.append(writer)
            WS_SOCKETS.append(self.connection)
        try:
            self._websocket_loop(reader, writer)
        finally:
            with LOCK:
                if writer in WS_WRITERS:
                    WS_WRITERS.remove(writer)
                if self.connection in WS_SOCKETS:
                    WS_SOCKETS.remove(self.connection)

    def _websocket_loop(self, reader, writer):
        while True:
            frame = read_frame(reader)
            if frame is None:
                return
            payload, opcode = frame
            if opcode == 0x8:
                return
            if opcode == 0x9:
                writer.write(bytes([0x8A, len(payload)]) + payload)
                writer.flush()
                continue
            if opcode != 0x1:
                continue
            try:
                message = json.loads(payload)
            except ValueError:
                continue
            print("WS frame", json.dumps(message)[:120], flush=True)
            if message.get("type") == "open" and message.get("streamId") == "$events":
                send_text(writer, json.dumps({
                    "type": "item", "streamId": "$events",
                    "value": {"type": "ready", "clientId": "stub-client"},
                }))

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            request = json.loads(raw or b"{}")
        except ValueError:
            request = {}
        method = request.get("method", "")
        args = (request.get("payload") or {}).get("args") or {}
        value = rpc_value(method, args)
        body = json.dumps({"type": "client-response", "rpcId": request.get("rpcId", ""),
                           "result": {"ok": True, "value": value}}).encode()
        self._send(200, body, {"Content-Type": "application/json"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"review3 stub on http://127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
