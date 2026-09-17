#!/usr/bin/env python3
"""Real host termination probe: SIGTERM and SIGINT must stop the host cleanly.

Runs the debug ``harness --host`` against an isolated temporary workspace, an
unused loopback port and an unreachable provider that is never called (no
session or turn is opened). Each signal is tested in its own process: once the
TCP listener accepts connections, the probe delivers the signal, requires the
process to exit within five seconds and requires exit status 0, so a SIGTRAP,
a hang or a skipped cleanup all fail. The probe only ever touches the process
and temporary directory it created.
"""
import argparse
import json
import os
from pathlib import Path
import secrets
import shutil
import signal
import socket
import subprocess
import tempfile
import time

READY_BOUND_SECONDS = 10.0
EXIT_BOUND_SECONDS = 5.0
# The listener becomes reachable inside NativeHost.start(), while the host
# installs its signal sources immediately afterwards. Give the host a short,
# bounded settle so the signal is delivered to the installed handler instead of
# the not-yet-replaced default disposition (which would exit with -SIGTERM).
SIGNAL_SETTLE_SECONDS = 0.5
# macOS bind-to-zero can return a port that is still in TIME_WAIT, which the
# host listener then rejects with EADDRINUSE before it is ever reachable.
# Retrying startup on that specific error is safe: the defect under test only
# manifests after a live listener, so a retry cannot hide it.
STARTUP_ATTEMPTS = 5
# The provider is constructed but never contacted: no session or turn is ever
# opened, so a dead loopback endpoint cannot affect the termination path.
UNREACHABLE_PROVIDER = "http://127.0.0.1:1/v1"


def free_loopback_port():
    """Ask the kernel for an unused loopback port (bind-to-zero), then release it."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def wait_for_listener(port, process, timeout):
    """Boundedly TCP-connect the host listener; False if it never accepts."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            return False
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.25):
                return True
        except OSError:
            time.sleep(0.05)
    return False


def sanitized(text, token, directory):
    return text.replace(token, "<token>").replace(directory, "<workspace>")


def probe_signal(binary, signum):
    name = signal.Signals(signum).name
    last_log = ""
    for attempt in range(1, STARTUP_ATTEMPTS + 1):
        directory = tempfile.mkdtemp(prefix="native-signal-probe-")
        token = secrets.token_hex(32)  # 64 ASCII bytes, above the 32-byte host minimum
        port = free_loopback_port()
        env = dict(os.environ,
                   HARNESS_BASE_URL=UNREACHABLE_PROVIDER,
                   HARNESS_MODEL="fixture",
                   HARNESS_HOST_TOKEN=token,
                   HARNESS_HOST_PORT=str(port))
        env.pop("HARNESS_API_KEY", None)
        command = [str(binary), "--host", "--workspace", directory,
                   "--store", str(Path(directory) / "events.sqlite")]
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            if not wait_for_listener(port, process, READY_BOUND_SECONDS):
                if process.poll() is None:
                    process.kill()
                stdout, stderr = process.communicate()
                last_log = sanitized((stdout or "") + (stderr or ""), token, directory)
                if "Address already in use" in last_log and attempt < STARTUP_ATTEMPTS:
                    continue
                raise AssertionError("%s: listener never became reachable\n%s" % (name, last_log[-2000:]))
            time.sleep(SIGNAL_SETTLE_SECONDS)
            started = time.monotonic()
            process.send_signal(signum)
            try:
                stdout, stderr = process.communicate(timeout=EXIT_BOUND_SECONDS)
            except subprocess.TimeoutExpired:
                process.kill()
                stdout, stderr = process.communicate()
                raise AssertionError("%s: did not exit within %.0f seconds\n%s" % (
                    name, EXIT_BOUND_SECONDS,
                    sanitized((stdout or "") + (stderr or ""), token, directory)[-2000:]))
            elapsed = time.monotonic() - started
            if process.returncode != 0:
                raise AssertionError("%s: exited with %r\n%s" % (
                    name, process.returncode,
                    sanitized((stdout or "") + (stderr or ""), token, directory)[-2000:]))
            return {"signal": name, "status": "passed",
                    "exitCode": process.returncode, "elapsedSeconds": round(elapsed, 3)}
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            shutil.rmtree(directory, ignore_errors=True)
    raise AssertionError("%s: listener never became reachable after %d attempts\n%s" % (
        name, STARTUP_ATTEMPTS, last_log[-2000:]))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, default=Path("NativeHarness/.build/debug/harness"))
    args = parser.parse_args()
    binary = args.binary.resolve()
    assert binary.is_file(), "harness binary not found: %s" % binary
    for number in (signal.SIGTERM, signal.SIGINT):
        print(json.dumps(probe_signal(binary, number)), flush=True)
