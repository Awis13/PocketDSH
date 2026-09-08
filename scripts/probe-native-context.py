#!/usr/bin/env python3
"""Development-only HTTP budget probes. Uses isolated stores and no real model."""
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
    measured = threading.Event()
    counted, generated, redirected = [], [], []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            assert self.path.startswith('/props?'), self.path
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'{"default_generation_settings":{"n_ctx":500},"n_ctx_train":99999}')

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get('Content-Length', 0)))
            if self.path.endswith('/input_tokens'):
                counted.append(body)
                measured.set()
                if scenario == 'cancel':
                    time.sleep(2)
                    return
                if scenario == 'timeout':
                    time.sleep(4)
                    return
                if scenario == 'unsupported':
                    self.send_response(404)
                    self.end_headers()
                    return
                if scenario == 'redirect':
                    self.send_response(307)
                    self.send_header('Location', f'http://127.0.0.1:{self.server.server_port}/leaked')
                    self.end_headers()
                    return
                self.send_response(200)
                self.end_headers()
                tokens = 480 if scenario == 'overflow' else 100
                self.wfile.write(json.dumps({'object': 'response.input_tokens', 'input_tokens': tokens}).encode())
                return
            if self.path == '/leaked':
                redirected.append(body)
            assert self.path == '/v1/chat/completions', self.path
            generated.append(body)
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            frames = [
                {'choices': [{'index': 0, 'delta': {'content': 'BUDGET_OK'}, 'finish_reason': 'stop'}]},
                {'choices': [], 'usage': {'prompt_tokens': 100, 'completion_tokens': 2, 'total_tokens': 102}},
            ]
            for frame in frames:
                self.wfile.write(('data: ' + json.dumps(frame) + '\n\n').encode())
            if scenario != 'truncated':
                self.wfile.write(b'data: [DONE]\n\n')
            self.wfile.flush()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='native-context-probe-') as directory:
            root = Path(directory)
            env = dict(os.environ, HARNESS_BASE_URL=f'http://127.0.0.1:{server.server_port}/v1',
                       HARNESS_MODEL='fixture', HARNESS_PROVIDER_PROFILE='llama-cpp', HARNESS_OUTPUT_TOKENS='64')
            for key in ['HARNESS_API_KEY', 'HARNESS_CONTEXT_TOKENS', 'HARNESS_INCLUDE_USAGE', 'HARNESS_DISABLE_THINKING']:
                env.pop(key, None)
            trace = root / 'trace.json'
            command = [str(binary), '--workspace', directory, '--store', str(root / 'events.sqlite'),
                       '--session', 'fixture', '--prompt', 'PRIVATE_PROMPT', '--trace', str(trace)]
            process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert measured.wait(10), 'Count endpoint not reached'
                if scenario == 'cancel':
                    process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=12)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()
            expected_success = scenario not in ['overflow', 'cancel', 'truncated']
            assert (process.returncode == 0) == expected_success, (scenario, stdout, stderr)
            assert len(counted) == 1 and not redirected, (scenario, counted, redirected)
            assert len(generated) == (0 if scenario in ['overflow', 'cancel'] else 1), scenario
            if generated:
                assert counted[0] == generated[0], 'Count and generation bodies differ'
            payload = json.loads(counted[0])
            assert payload['max_tokens'] == 64 and payload['stream_options']['include_usage'] is True
            assert payload['messages'][0]['role'] == 'system' and payload['tools']
            report = json.loads(trace.read_text())
            last = report['events'][-1]
            if scenario == 'overflow':
                assert last['code'] == 'CONTEXT_LIMIT', report
            if scenario == 'cancel':
                assert last['stage'] == 'cancelled', report
            assert 'PRIVATE_PROMPT' not in trace.read_text()
            with sqlite3.connect(root / 'events.sqlite') as connection:
                events = [json.loads(row[0]) for row in connection.execute('SELECT body FROM events ORDER BY seq')]
            messages = [event['message'] for event in events if 'message' in event]
            assert messages[0]['content'] == 'PRIVATE_PROMPT'
            assert sum(message['role'] == 'assistant' for message in messages) == int(expected_success)
            return {'scenario': scenario, 'stage': last['stage'], 'countRequests': len(counted), 'generationRequests': len(generated)}
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=Path('NativeHarness/.build/debug/harness'))
    args = parser.parse_args()
    for scenario in ['fit', 'overflow', 'unsupported', 'timeout', 'redirect', 'cancel', 'truncated']:
        print(json.dumps(probe(args.binary.resolve(), scenario)), flush=True)
