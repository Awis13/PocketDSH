#!/usr/bin/env python3
"""Opt-in compaction through the real CLI, HTTP/SSE provider and SQLite store.

The loopback provider reports deterministic byte-based fixture counts, not a
real tokenizer. No production endpoint, workspace, process or database is used.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile
import threading


def probe(binary, invalid=False):
    counted, generated = [], []
    capacity = 15000
    summary = 'Historical work was inspected; preserve user constraints and verify unknown outcomes before retrying.'

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(json.dumps({'default_generation_settings': {'n_ctx': capacity}}).encode())

        def do_POST(self):
            raw = self.rfile.read(int(self.headers['Content-Length']))
            body = json.loads(raw)
            if self.path.endswith('/input_tokens'):
                counted.append(raw)
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps({'object': 'response.input_tokens', 'input_tokens': len(raw)}).encode())
                return
            generated.append(raw)
            assert raw in counted, 'Generation must use measured bytes'
            assert len(raw) + body['max_tokens'] <= capacity, 'Oversized generation request'
            is_summary = body['messages'][-1]['content'].startswith('Summarize historical')
            if is_summary:
                assert body['tools'] == []
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            message = summary if is_summary else 'CONTINUED'
            frame = {'choices': [{'delta': {'content': message}, 'finish_reason': 'length' if invalid and is_summary else 'stop'}]}
            self.wfile.write(('data: ' + json.dumps(frame) + '\n\ndata: [DONE]\n\n').encode())
            self.wfile.flush()

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix='native-compaction-probe-') as directory:
            root = Path(directory)
            db = root / 'events.sqlite'
            with sqlite3.connect(db) as connection:
                connection.execute('CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, body TEXT NOT NULL)')
                for index in range(6):
                    content = str(index) + 'x' * (6000 if index < 4 else 20)
                    for event in [dict(kind='turn.started'), dict(kind='message', message=dict(role='user', content=content, calls=[])),
                                  dict(kind='message', message=dict(role='assistant', content=content, calls=[])), dict(kind='turn.ended')]:
                        connection.execute('INSERT INTO events(session,body) VALUES (?,?)', ('fixture', json.dumps(event)))
                original = connection.execute('SELECT seq,body FROM events ORDER BY seq').fetchall()
            env = dict(os.environ, HARNESS_BASE_URL=f'http://127.0.0.1:{server.server_port}/v1', HARNESS_MODEL='fixture',
                       HARNESS_PROVIDER_PROFILE='llama-cpp', HARNESS_OUTPUT_TOKENS='64')
            for key in ['HARNESS_API_KEY', 'HARNESS_CONTEXT_TOKENS', 'HARNESS_INCLUDE_USAGE', 'HARNESS_DISABLE_THINKING']:
                env.pop(key, None)

            def run(prompt, trace):
                return subprocess.run([str(binary), '--workspace', directory, '--store', str(db), '--session', 'fixture',
                                       '--prompt', prompt, '--trace', str(root / trace)], env=env, capture_output=True, text=True, timeout=30)

            process = run('continue', 'first.json')
            assert (process.returncode == 0) != invalid, process.stderr
            assert summary not in process.stdout, 'Summary leaked into the user answer'
            with sqlite3.connect(db) as connection:
                assert connection.execute('SELECT seq,body FROM events WHERE seq<=24 ORDER BY seq').fetchall() == original
                receipt = json.loads(connection.execute('SELECT receipt FROM context_operations').fetchone()[0])
                projection = connection.execute('SELECT projection FROM context_state WHERE session=?', ('fixture',)).fetchone()[0]
                events = [json.loads(row[0]) for row in connection.execute('SELECT body FROM events ORDER BY seq')]
            assert not any(event['kind'] == 'tool.started' for event in events), 'Compaction dispatched tools'
            if invalid:
                assert receipt['state'] == 'failed' and receipt['code'] == 'COMPACTION_INVALID_SUMMARY'
                assert projection is None and len(generated) == 1
            else:
                assert receipt['state'] == 'completed' and 1 < receipt['summaryRequests'] <= 4
                assert 'CONTINUED' in process.stdout and projection is not None
                before = len(generated)
                restarted = run('after restart', 'second.json')
                assert restarted.returncode == 0, restarted.stderr
                assert len(generated) == before + 1, 'Restart repeated summarization'
                request = json.loads(generated[-1])
                assert request['messages'][1]['content'].startswith('[Earlier conversation summary')
                assert request['messages'][-1]['content'] == 'after restart'
                report = json.loads((root / 'first.json').read_text())
                summaries = [request for request in report['requests'] if request.get('purpose') == 'compaction' and request.get('dispatched')]
                assert len(summaries) == receipt['summaryRequests']
                assert all(request['stage'] == 'modelCompleted' for request in summaries)
            print(json.dumps({'scenario': 'invalid-summary' if invalid else 'compact-and-restart',
                              'state': receipt['state'], 'summaryRequests': receipt['summaryRequests'],
                              'generationRequests': len(generated), 'originalRowsPreserved': len(original)}), flush=True)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=Path('NativeHarness/.build/debug/harness'))
    args = parser.parse_args()
    probe(args.binary.resolve())
    probe(args.binary.resolve(), invalid=True)
