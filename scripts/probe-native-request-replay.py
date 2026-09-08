#!/usr/bin/env python3
"""Isolated WebSocket/journal request diagnostics, optionally held for visual QA."""
import argparse
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time


def run(binary, client, hold):
    generated = []

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"default_generation_settings":{"n_ctx":32768}}')

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            if self.path.endswith('/input_tokens'):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"object":"response.input_tokens","input_tokens":12345}')
                return
            generated.append(body)
            if body['messages'][-1]['content'] == 'DIAGNOSTIC_HTTP_FAILURE':
                self.send_response(400)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            answer = ('The request budget is visible above the conversation.\n\n'
                      '| Measurement | Tokens |\n| :--- | ---: |\n| Input | 12,345 |\n| Output reserve | 4,096 |\n| Capacity | 32,768 |\n\n'
                      'Open **Request details** to inspect timings and provider usage. The same data stays available in Shell and Chat.')
            frames = [
                {'choices': [{'delta': {'reasoning_content': 'Checking context capacity and the output reserve.'}}]},
                {'choices': [{'delta': {'content': answer}, 'finish_reason': 'stop'}]},
                {'choices': [], 'usage': {'prompt_tokens': 12345, 'completion_tokens': 240, 'total_tokens': 12585,
                                          'prompt_tokens_details': {'cached_tokens': 512}, 'completion_tokens_details': {'reasoning_tokens': 80}}},
            ]
            for frame in frames:
                self.wfile.write(('data: ' + json.dumps(frame) + '\n\n').encode()); self.wfile.flush()
                time.sleep(.1)
            self.wfile.write(b'data: [DONE]\n\n'); self.wfile.flush()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host = None
    with tempfile.TemporaryDirectory(prefix='pocketdsh-request-') as directory:
        root = Path(directory)
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0)); port = reservation.getsockname()[1]
        token = secrets.token_hex(32)
        config = root / 'connection.json'
        config.write_text(json.dumps({'endpoint': f'ws://127.0.0.1:{port}', 'token': token}))
        config.chmod(0o600)
        env = dict(os.environ, HARNESS_BASE_URL=f'http://127.0.0.1:{server.server_port}/v1', HARNESS_MODEL='diagnostic-fixture',
                   HARNESS_HOST_PORT=str(port), HARNESS_HOST_TOKEN=token, HARNESS_PROVIDER_PROFILE='llama-cpp', HARNESS_OUTPUT_TOKENS='4096')
        for key in ['HARNESS_API_KEY', 'HARNESS_CONTEXT_TOKENS', 'HARNESS_INCLUDE_USAGE', 'HARNESS_DISABLE_THINKING']:
            env.pop(key, None)

        def start():
            with (root / 'host.log').open('ab') as log:
                process = subprocess.Popen([str(binary), '--host', '--workspace', directory, '--store', str(root / 'events.sqlite')],
                                           env=env, stdout=log, stderr=log)
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError('Isolated host failed to start')
                try:
                    with socket.create_connection(('127.0.0.1', port), .1):
                        return process
                except OSError:
                    time.sleep(.05)
            process.kill(); process.wait()
            raise RuntimeError('Isolated host timed out')

        try:
            host = start()
            subprocess.run([str(client), directory, 'live'], check=True, timeout=40)
            host.terminate(); host.wait(timeout=10)
            host = start()
            before = len(generated)
            subprocess.run([str(client), directory, 'replay'], check=True, timeout=40)
            assert len(generated) == before == 2, 'Restart/replay must not run the model again'
            print('PASS restart: both final requests retained; no generation repeated', flush=True)
            if hold:
                print('Visual QA config: ' + str(config), flush=True)
                input('Press Enter to stop the isolated host and remove temporary state.\n')
        finally:
            if host and host.poll() is None:
                host.terminate()
                try: host.wait(timeout=10)
                except subprocess.TimeoutExpired: host.kill(); host.wait()
            server.shutdown(); server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=Path('NativeHarness/.build/debug/harness'))
    parser.add_argument('--client', type=Path, default=Path('.build/checks/native-request-replay'))
    parser.add_argument('--hold', action='store_true')
    args = parser.parse_args()
    run(args.binary.resolve(), args.client.resolve(), args.hold)
