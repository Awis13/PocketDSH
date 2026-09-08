#!/usr/bin/env python3
"""Summarize a completed local paired run; never infer missing measurements."""
import json, statistics, sys, subprocess
from pathlib import Path
root=Path(sys.argv[1]);rows=json.loads((root/'results.json').read_text())
# Independent holdout checks are never placed in the model-visible fixture.
for r in rows:
 if r['scenario']=='fix' and r.get('workspace'):
  code='''from cache import is_fresh, Cache
for expiry in [-100, -0.5, 0, 0.5, 1, 10, 100000]:
    assert is_fresh(expiry, expiry-0.001) is True
    assert is_fresh(expiry, expiry) is False
    assert is_fresh(expiry, expiry+0.001) is False
for ttl in [0, 1, 5, 30]:
    c=Cache(ttl); c.put("x", "y", 10)
    assert c.get("x",10+ttl) is None
    assert c.get("missing",10) is None
print("HOLDOUT_OK")
'''
  p=subprocess.run(['/usr/bin/python3','-c',code],cwd=r['workspace'],capture_output=True,text=True,timeout=10)
  r['holdout_passed']=p.returncode==0;r['correct']=r['correct'] and r['holdout_passed']
  (root/f"{r['round']}-fix-{r['engine']}.holdout.log").write_text(p.stdout+p.stderr)
(root/'results-validated.json').write_text(json.dumps(rows,indent=2))
def value(group,key):
 xs=[r[key] for r in group if isinstance(r.get(key),(int,float))]
 return f'{statistics.median(xs):.2f}' if xs else 'n/a'
lines=['# Harness comparison — local mini-benchmark','', '| Scenario | Engine | Correct | First visible output, median s | First answer text, median s | Completion, median s | Tool calls |','|---|---|---:|---:|---:|---:|---:|']
for scenario in ['short','inspect','fix','long']:
 for engine in ['native','dsh']:
  g=[r for r in rows if r['scenario']==scenario and r['engine']==engine]
  lines.append(f"| {scenario} | {engine} | {sum(r['correct'] for r in g)}/{len(g)} | {value(g,'first_activity_s')} | {value(g,'first_text_s')} | {value(g,'total_s')} | {value(g,'tools')} |")
lines += ['', '## Method and limits', '',
 '- Two fresh sessions per scenario and engine, alternating order. One run at a time. Same Home Rig qwen3.8-27b endpoint. Setup and compilation excluded from turn timing.',
 '- Separate copies of the same four-file Python fixture. Fix correctness checked by unchanged test files, four unit tests, and independent holdout boundary cases.',
 '- Short-answer correctness requires exact BENCH_READY; investigation must identify 30 seconds, POCKET_CACHE_TTL, and is_fresh; long output requires exactly 100 specified lines.',
 '- These are current product configurations: DSH has a larger system prompt, more tools/plugins and reasoningEffort=xhigh. Native uses its small tool set and temperature 0.1. This is not a language-only or equal-prompt comparison.',
 '- DSH live assistant-stream was explicitly enabled. Its current protocol otherwise only sends the committed assistant message to this follow subscriber. The older Pocket DSH subscription lacks this option; that UI integration issue is separate from engine throughput.',
 '- Cache was not flushed, model was not unloaded, and external server traffic was not locked out. Treat this as alternating warm/mixed-cache operation, not controlled cold-start evidence.',
 '- First output means a received reasoning/text delta or tool call. First text excludes reasoning. Completion is the engine end marker. Approval decisions were immediate for these authorized fixture tasks.',
 '- Wire stream timing is measured here; UI frame rate, scrolling responsiveness and physical iPad rendering are not measured. Two samples per scenario are preliminary, not a stable population estimate.',
 '- Raw event logs, prompts, individual results and validation output accompany this report. Failed instrumentation attempts are stored separately and excluded.'
]
(root/'REPORT.md').write_text('\n'.join(lines)+'\n')
print('\n'.join(lines[:12]))
