#!/usr/bin/env python3
"""Opt-in, isolated host/HTTP/SQLite compaction controls. Counts are fixture bytes, not tokenizer tokens."""
import argparse
import http.server
import json
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import uuid


def run(binary, client, hold):
    generated = []
    mode = 'manual'
    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            self.send_response(200); self.end_headers()
            self.wfile.write(b'{"default_generation_settings":{"n_ctx":15000}}' if mode != 'unknown' else b'{}')
        def do_POST(self):
            raw = self.rfile.read(int(self.headers['Content-Length'])); body = json.loads(raw)
            if self.path.endswith('/input_tokens'):
                self.send_response(200); self.end_headers()
                self.wfile.write(json.dumps({'object': 'response.input_tokens', 'input_tokens': len(raw)}).encode()); return
            summary = body['messages'][-1]['content'].startswith('Summarize historical')
            generated.append((mode, body))
            assert len(raw) + body['max_tokens'] <= 15000
            if summary: assert body['tools'] == []
            if mode in ('cancel', 'crash'): time.sleep(3)
            self.send_response(200); self.send_header('Content-Type', 'text/event-stream'); self.end_headers()
            text = 'Historical facts retained. Keep user constraints; check unknown outcomes before retrying.' if summary else 'CONTINUED'
            frame = {'choices': [{'delta': {'content': text}, 'finish_reason': 'stop'}]}
            try: self.wfile.write(('data: ' + json.dumps(frame) + '\n\ndata: [DONE]\n\n').encode()); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError): pass
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    host = None
    with tempfile.TemporaryDirectory(prefix='pocketdsh-c5-') as directory:
        root = Path(directory); db = root/'events.sqlite'
        with socket.socket() as s: s.bind(('127.0.0.1', 0)); port=s.getsockname()[1]
        config = {name: str(uuid.uuid4()) for name in ['manual', 'auto', 'cancel', 'crash', 'unknown']}
        config.update(endpoint=f'ws://127.0.0.1:{port}', token=secrets.token_hex(32))
        (root/'connection.json').write_text(json.dumps(config)); (root/'connection.json').chmod(0o600)
        originals = []
        # Seed old-format journals so both the model source and UI transcript are exercised.
        with sqlite3.connect(db) as c, sqlite3.connect(str(db)+'.native.sqlite') as ui:
            c.execute('CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, session TEXT NOT NULL, body TEXT NOT NULL)')
            ui.executescript('CREATE TABLE panels(id TEXT PRIMARY KEY, metadata TEXT NOT NULL); CREATE TABLE output(session TEXT NOT NULL, seq INTEGER NOT NULL, body TEXT NOT NULL, PRIMARY KEY(session,seq));')
            for name in ['manual', 'auto', 'cancel', 'crash', 'unknown']:
                sid=config[name]; seq=0
                ui.execute('INSERT INTO panels VALUES (?,?)',(sid,json.dumps(dict(id=sid,title='Context check '+name,workspace=directory,model='fixture',running=False,updatedAt=0))))
                for i in range(6):
                    content=str(i)+'x'*(6000 if i<4 else 20)
                    events=[dict(kind='turn.started'), dict(kind='message',message=dict(role='user',content=content,calls=[])),dict(kind='message',message=dict(role='assistant',content=content,calls=[])),dict(kind='turn.ended')]
                    for e in events: c.execute('INSERT INTO events(session,body) VALUES (?,?)',(sid,json.dumps(e)))
                    for e in [dict(op='user',id=f'user-{i}',text=content),dict(op='text',text=content),dict(op='stage',stage='completed')]:
                        seq+=1;e.update(session=sid,sequence=seq);ui.execute('INSERT INTO output VALUES (?,?,?)',(sid,seq,json.dumps(e)))
            originals=c.execute('SELECT seq,session,body FROM events ORDER BY seq').fetchall()
        env=dict(os.environ,HARNESS_BASE_URL=f'http://127.0.0.1:{server.server_port}/v1',HARNESS_MODEL='fixture',HARNESS_HOST_PORT=str(port),HARNESS_HOST_TOKEN=config['token'],HARNESS_PROVIDER_PROFILE='llama-cpp',HARNESS_OUTPUT_TOKENS='64')
        for k in ['HARNESS_API_KEY','HARNESS_CONTEXT_TOKENS','HARNESS_INCLUDE_USAGE','HARNESS_DISABLE_THINKING']: env.pop(k,None)
        def start():
            with (root/'host.log').open('ab') as log: p=subprocess.Popen([str(binary),'--host','--workspace',directory,'--store',str(db)],env=env,stdout=log,stderr=log)
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                if p.poll() is not None: raise RuntimeError((root/'host.log').read_text())
                try:
                    with socket.create_connection(('127.0.0.1',port),.1): return p
                except OSError: time.sleep(.05)
            p.kill();p.wait();raise RuntimeError('host timeout')
        def phase(name): subprocess.run([str(client),directory,name],check=True,timeout=45)
        try:
            host=start()
            phase('manual'); mode='auto';phase('auto');mode='cancel';phase('cancel')
            mode='crash';phase('crash');host.kill();host.wait()
            before=len(generated);host=start();phase('replay')
            assert len(generated)==before, 'Restart/retry started inference'
            mode='unknown';phase('unknown')
            with sqlite3.connect(db) as c:
                assert c.execute('SELECT seq,session,body FROM events WHERE seq<=? ORDER BY seq',(len(originals),)).fetchall()==originals
                receipts=[json.loads(r[0]) for r in c.execute('SELECT receipt FROM context_operations')]
                assert sorted(r['state'] for r in receipts)==['cancelled','completed','completed','failed','interrupted']
            for name in ['manual','auto']:
                requests=[body for phase,body in generated if phase==name]
                assert len(requests)==5, (name,len(requests))
                assert requests[-1]['messages'][1]['content'].startswith('[Earlier conversation summary')
            assert not any(phase=='unknown' for phase,_ in generated)
            print('PASS integrated: manual/auto, Stop/BUSY/retry, unknown capacity, crash/replay, projection reuse, 120 source rows preserved',flush=True)
            if hold:
                print('Visual replay directory: '+directory,flush=True)
                input('Enter to stop isolated fixture and remove its state.\n')
        finally:
            if host and host.poll() is None:
                host.terminate()
                try: host.wait(timeout=10)
                except subprocess.TimeoutExpired: host.kill();host.wait()
            server.shutdown();server.server_close()

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--binary',type=Path,default=Path('NativeHarness/.build/debug/harness'));p.add_argument('--client',type=Path,default=Path('.build/checks/native-context-checks'));p.add_argument('--hold',action='store_true');args=p.parse_args()
    run(args.binary.resolve(),args.client.resolve(),args.hold)
