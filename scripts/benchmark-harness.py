#!/usr/bin/env python3
"""Opt-in local comparison. Creates isolated fixtures and DSH benchmark sessions."""
import json, os, secrets, socket, subprocess, time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
if not os.environ.get('HARNESS_BASE_URL') or not os.environ.get('HARNESS_MODEL'):
 raise SystemExit('Set HARNESS_BASE_URL and HARNESS_MODEL for your test provider before running this opt-in benchmark.')
OUT=ROOT/'output/harness-benchmark'
RUN=OUT/time.strftime('%Y%m%d-%H%M%S');RUN.mkdir(parents=True)
common='This is an isolated benchmark fixture. Work only inside this working directory. Do not read global instructions, memories, other projects or network resources. Do not delegate. '
prompts={
 'short':'Do not call tools. Reply with exactly BENCH_READY.',
 'inspect':common+'Inspect the Python files and identify the default TTL in seconds, the configuration key that overrides it, and the function that checks expiration. Do not edit or execute anything. Reply in one sentence.',
 'fix':common+'Fix the cache expiration boundary: an item must be expired when now equals expires_at. Inspect the code, make the smallest change to cache.py, and run python3 -m unittest -q. Do not modify tests. Report the test result briefly.',
 'long':'Do not call tools. Output exactly 100 numbered lines. Line N must be: N. Streaming benchmark line. No introduction or conclusion.'
}
files={
 'cache.py':'''def is_fresh(expires_at, now):
    return now <= expires_at

class Cache:
    def __init__(self, ttl):
        self.ttl = ttl
        self.entries = {}
    def put(self, key, value, now):
        self.entries[key] = (value, now + self.ttl)
    def get(self, key, now):
        entry = self.entries.get(key)
        if entry is None or not is_fresh(entry[1], now):
            return None
        return entry[0]
''',
 'config.py':'''def load_config(env):
    return {"ttl": int(env.get("POCKET_CACHE_TTL", "30"))}
''',
 'app.py':'''from cache import Cache
from config import load_config

def make_cache(env):
    return Cache(load_config(env)["ttl"])
''',
 'test_cache.py':'''import unittest
from app import make_cache
class Tests(unittest.TestCase):
    def test_before(self):
        c = make_cache({}); c.put("key", "value", 100)
        self.assertEqual(c.get("key", 129), "value")
    def test_boundary(self):
        c = make_cache({}); c.put("key", "value", 100)
        self.assertIsNone(c.get("key", 130))
    def test_after(self):
        c = make_cache({}); c.put("key", "value", 100)
        self.assertIsNone(c.get("key", 131))
    def test_override(self):
        c = make_cache({"POCKET_CACHE_TTL": "5"}); c.put("key", "v", 10)
        self.assertEqual(c.get("key", 14), "v")
        self.assertIsNone(c.get("key", 15))
'''
}
CANCEL=os.environ.get('HARNESS_BENCH_CANCEL')=='1'
if CANCEL: prompts={'cancel':'Do not call tools. Output 2000 numbered lines, each containing Streaming cancellation benchmark.'}
print('Run:',RUN,flush=True)
results=[]
for round in range(1 if CANCEL else 2):
 for scenario,prompt in prompts.items():
  order=['native','dsh'] if (round+list(prompts).index(scenario))%2==0 else ['dsh','native']
  for engine in order:
   name=f'{round+1}-{scenario}-{engine}'; ws=RUN/name;ws.mkdir()
   for file,content in files.items(): (ws/file).write_text(content)
   promptfile=RUN/(name+'.prompt.txt');promptfile.write_text(prompt)
   host=None; log=None
   try:
    if engine=='native':
     token=secrets.token_urlsafe(36);port=8784
     config=RUN/'native-connection.json';config.write_text(json.dumps({'endpoint':f'ws://127.0.0.1:{port}','token':token}));config.chmod(0o600)
     env=dict(os.environ,HARNESS_HOST_TOKEN=token,HARNESS_HOST_PORT=str(port));env.pop('HARNESS_DISABLE_THINKING',None)
     log=open(RUN/(name+'.host.log'),'w')
     host=subprocess.Popen([str(ROOT/'NativeHarness/.build/debug/harness'),'--host','--workspace',str(ws),'--store',str(RUN/(name+'.sqlite'))],env=env,stdout=log,stderr=log)
     for _ in range(100):
      if host.poll() is not None: raise RuntimeError('Native host failed to start')
      try:
       with socket.create_connection(('127.0.0.1',port),timeout=.1): pass
       break
      except OSError: time.sleep(.05)
    resultfile=RUN/(name+'.json')
    cmd=[str(OUT/('bench-cancel' if CANCEL else 'bench')),engine,str(ws),str(promptfile),str(resultfile)]
    if engine=='native':cmd.append(str(config))
    process=subprocess.run(cmd,capture_output=True,text=True,timeout=150)
    (RUN/(name+'.runner.log')).write_text(process.stdout+process.stderr)
    print(name,process.stdout.strip() or process.stderr[-250:],flush=True)
    if resultfile.exists(): result=json.loads(resultfile.read_text())
    else: result={'engine':engine,'outcome':'runner_error','total_s':None}
    result.update(round=round+1,scenario=scenario)
    answer=result.get('text','')
    if scenario=='cancel':correct=result.get('cancel_to_end_s') is not None and result.get('outcome') in ['cancelled','interrupted','aborted']
    elif scenario=='short':correct=answer.strip()=='BENCH_READY'
    elif scenario=='inspect':correct=all(x in answer for x in ['30','POCKET_CACHE_TTL','is_fresh'])
    elif scenario=='long':correct=answer.strip().splitlines()==[f'{i}. Streaming benchmark line.' for i in range(1,101)]
    else:
     unchanged=all((ws/f).read_text()==c for f,c in files.items() if f!='cache.py')
     test=subprocess.run(['/usr/bin/python3','-m','unittest','-q'],cwd=ws,capture_output=True,text=True,timeout=10)
     (RUN/(name+'.validation.log')).write_text(test.stdout+test.stderr)
     correct=test.returncode==0 and unchanged
     result['tests_unchanged']=unchanged
    result['correct']=correct;results.append(result)
    (RUN/'results.json').write_text(json.dumps(results,indent=2))
   finally:
    if host:
     host.terminate()
     try:host.wait(timeout=5)
     except subprocess.TimeoutExpired:host.kill();host.wait()
    if log:log.close()
print('Finished:',RUN,flush=True)
