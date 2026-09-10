#!/usr/bin/env python3
"""An agent joins a running PTY and waits for later output through real CLI tools."""
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


def probe(binary):
    requests = []
    wait_started = threading.Event()
    observed_late = False
    terminal_id = None

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            nonlocal observed_late
            body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
            requests.append(body)
            results = [m for m in body['messages'] if m['role'] == 'tool']
            name, arguments = 'terminal_inspect', {}
            if results:
                result = json.loads(results[-1]['content'])
                if isinstance(result, list):
                    name, arguments = 'terminal_read', {'terminal_id': terminal_id, 'after': '0'}
                else:
                    # Model-facing excerpts normalize CR and strip terminal controls.
                    # Require a complete output line, not the echoed shell command.
                    assert 'bytes' not in result and '\x1b' not in result['text']
                    observed_late = observed_late or 'OBS_LATE' in result['text'].splitlines()
                    if observed_late:
                        name = None
                    else:
                        name, arguments = 'terminal_wait', {'terminal_id': terminal_id, 'after': str(result['nextCursor']), 'timeout_seconds': '5'}
                        wait_started.set()
            if name:
                delta = {'tool_calls': [{'index': 0, 'id': 'call-'+str(len(requests)), 'type':'function', 'function': {'name': name, 'arguments': json.dumps(arguments)}}]}
                reason='tool_calls'
            else:
                delta={'content':'WATCH_OK'}; reason='stop'
            self.send_response(200); self.send_header('Content-Type','text/event-stream'); self.end_headers()
            self.wfile.write(('data: '+json.dumps({'choices':[{'delta':delta,'finish_reason':reason}]})+'\n\ndata: [DONE]\n\n').encode())

    server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    with tempfile.TemporaryDirectory(prefix='observation-probe-') as root:
        env=dict(os.environ,HARNESS_BASE_URL=f'http://127.0.0.1:{server.server_port}/v1',HARNESS_MODEL='fixture')
        process=subprocess.Popen([binary,'--workspace',root,'--store',root+'/events.db','--session','observe','--interactive'],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        lines=queue.Queue(); threading.Thread(target=lambda:[lines.put(l) for l in process.stderr],daemon=True).start()
        answers=[];threading.Thread(target=lambda:answers.append(process.stdout.read()),daemon=True).start()
        def send(op,**fields):
            process.stdin.write(json.dumps(dict(op=op,**fields))+'\n');process.stdin.flush()
        def input_line(text): send('pty-input',ptyID=terminal_id,bytes=base64.b64encode(text.encode()+b'\r').decode())
        output=bytearray(); queued=False; running=False; inspection_sent=False; inspection_seen=False; ended=False; completed=False; closed=False
        send('pty-open')
        try:
            deadline=time.monotonic()+20
            while time.monotonic()<deadline:
                if process.poll() is not None and lines.empty(): break
                try: line=lines.get(timeout=.1)
                except queue.Empty: continue
                try: event=json.loads(line)
                except json.JSONDecodeError: event={}
                control=event.get('control')
                if control=='ptyOpened':
                    terminal_id=event['ptyID']; input_line("unsetopt zle; stty -echo; PS1=''; PS2=''; printf '\\nOBS_READY\\n'")
                if control=='ptyOutput':
                    output.extend(base64.b64decode(event['bytes']))
                    if b'\r\nOBS_READY\r\n' in output and not running:
                        running=True; input_line("printf '\\nOBS_EARLY\\n'; sleep 1.5; printf '\\nOBS_LATE\\n'; sleep 0.2; exit 0")
                    if b'\r\nOBS_EARLY\r\n' in output and not queued:
                        assert not requests, 'Model ran before user requested observation'
                        queued=True; send('queue',id='watch',prompt='Observe the running terminal without typing into it.')
                if '[tool: terminal_wait]' in line and not inspection_sent:
                    inspection_sent=True; send('pty-inspect')
                if control=='ptyInspection' and inspection_sent:
                    inspection_seen=not observed_late
                if control=='ptyExited': ended=True
                if '[turnCompleted ' in line: completed=True
                if ended and completed and not closed:
                    process.stdin.close();closed=True
            assert process.wait(timeout=3)==0
            events=[json.loads(r[0]) for r in sqlite3.connect(root+'/events.db').execute('SELECT body FROM events ORDER BY seq')]
            tools=[e['call']['name'] for e in events if e['kind']=='tool.started']
            assert tools[:3]==['terminal_inspect','terminal_read','terminal_wait'],tools
            assert wait_started.is_set() and observed_late and inspection_seen
            assert 'WATCH_OK' in ''.join(answers)
            assert not any(t in tools for t in ('shell','edit_file','terminal_send'))
            return {'status':'passed','tools':tools,'joinedRunningPTY':True,'readPastOutput':True,'waitSawLaterOutput':True,'controlResponsiveDuringWait':inspection_seen}
        finally:
            if process.poll() is None: process.kill();process.wait()
            server.shutdown();server.server_close()


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--binary',required=True);args=parser.parse_args()
    print(json.dumps(probe(str(Path(args.binary).resolve()))))
