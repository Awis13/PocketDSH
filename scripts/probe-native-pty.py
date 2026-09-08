#!/usr/bin/env python3
"""Real PTY/CLI checks: persistent shell, resize, job interrupt and tty restore."""
import argparse
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import queue
import select
import signal
import struct
import subprocess
import tempfile
import termios
import threading
import time


def forwarding(binary, root):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 25, 90, 0, 0))
    original = termios.tcgetattr(slave)
    process = subprocess.Popen([binary, '--terminal', '--workspace', root], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
    output = bytearray()

    def expect(marker, since=0):
        deadline = time.monotonic() + 8
        while marker not in output[since:]:
            assert time.monotonic() < deadline, (marker, bytes(output))
            if select.select([master], [], [], .1)[0]:
                output.extend(os.read(master, 65536))

    def send(command):
        os.write(master, command.encode() + b'\r')

    try:
        send("stty size; stty -a < /dev/tty >/dev/null && printf '\\nTTY_USABLE\\n'; export PTY_PROBE=kept; cd /")
        expect(b'25 90\r\n'); expect(b'\r\nTTY_USABLE\r\n')
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 38, 117, 0, 0))
        os.kill(process.pid, signal.SIGWINCH)
        time.sleep(.1)
        send("stty size; printf '\\n%s:%s\\n' \"$PTY_PROBE\" \"$PWD\"")
        expect(b'38 117\r\n'); expect(b'\r\nkept:/\r\n')
        send("printf '\\nSLEEPING\\n'; sleep 20")
        expect(b'\r\nSLEEPING\r\n'); time.sleep(.1)
        os.write(master, b'\x03')
        send("printf '\\nINTERRUPTED_OK\\n'")
        expect(b'\r\nINTERRUPTED_OK\r\n')
        send('vi -Nu NONE -n')
        expect(b'\x1b[?1049h')
        os.write(master, b'\x1b:q!\r')
        expect(b'\x1b[?1049l')
        expect(b'\x1b[?2004h', since=output.index(b'\x1b[?1049l') + 8)
        send("printf '\\nVIM_RETURNED\\n'")
        expect(b'\r\nVIM_RETURNED\r\n')
        send('exit 7')
        assert process.wait(timeout=5) == 7
        restored = termios.tcgetattr(slave)
        # Darwin may set PENDIN when returning to canonical input: a kernel
        # pending-input state bit, not a changed user terminal preference.
        restored[3] &= ~termios.PENDIN
        original[3] &= ~termios.PENDIN
        assert restored == original, ('Caller terminal attributes not restored', original, restored)
        return {'scenario': 'terminal-forwarder', 'status': 'passed', 'exitCode': 7, 'ttyRestored': True}
    finally:
        if process.poll() is None:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait()
        os.close(master); os.close(slave)


def controls(binary, root):
    env = dict(os.environ, HARNESS_BASE_URL='http://127.0.0.1:1/v1', HARNESS_MODEL='unused', HARNESS_API_KEY='must-not-inherit')
    process = subprocess.Popen([binary, '--workspace', root, '--store', root+'/pty.sqlite', '--session', 'pty-probe', '--interactive'], env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    events = queue.Queue()
    def reader():
        for line in process.stderr:
            try: events.put(json.loads(line))
            except json.JSONDecodeError: pass
    threading.Thread(target=reader, daemon=True).start()
    output = bytearray()
    def send(op, **fields):
        process.stdin.write(json.dumps(dict(op=op, **fields))+'\n'); process.stdin.flush()
    def until(control=None, marker=None):
        deadline = time.monotonic()+8
        if marker and marker in output: return {}
        while time.monotonic()<deadline:
            event = events.get(timeout=max(.01, deadline-time.monotonic()))
            if event['control'] == 'ptyOutput': output.extend(base64.b64decode(event['bytes']))
            if event['control'] == control or (marker and marker in output): return event
        raise AssertionError((control, marker, output))
    try:
        send('pty-open', rows=30, columns=100)
        first = until(control='ptyOpened')['ptyID']
        command = b"printf '\nKEY:%s\n' \"$HARNESS_API_KEY\"; stty size\r"
        send('pty-input', ptyID=first, bytes=base64.b64encode(command).decode())
        until(marker=b'\r\nKEY:\r\n'); until(marker=b'30 100\r\n')
        send('pty-resize', ptyID=first, rows=42, columns=120)
        send('pty-input', ptyID=first, bytes=base64.b64encode(b'stty size\r').decode())
        until(marker=b'42 120\r\n')
        send('pty-close', ptyID=first); until(control='ptyExited')
        send('pty-open'); second = until(control='ptyOpened')['ptyID']; assert first != second
        send('pty-input', ptyID=first, bytes=base64.b64encode(b'echo WRONG\r').decode())
        rejection = until(control='rejected'); assert 'stale' in rejection['error']
        process.stdin.close()
        assert process.wait(timeout=5)==0
        return {'scenario': 'pty-controls', 'status': 'passed', 'staleInputRejected': True, 'apiKeyExcluded': True}
    finally:
        if process.poll() is None: process.kill(); process.wait()


if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--binary', required=True); args=parser.parse_args()
    binary=str(Path(args.binary).resolve())
    with tempfile.TemporaryDirectory(prefix='native-pty-probe-') as root:
        print(json.dumps(forwarding(binary, root)), flush=True)
        print(json.dumps(controls(binary, root)), flush=True)
