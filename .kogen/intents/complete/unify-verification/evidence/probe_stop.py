"""Bounded native Stop semantics probe; no production implementation."""
from pathlib import Path
import subprocess,json,os,hashlib,time,shlex,signal
base=Path(__file__).resolve().parent
hook='''import json,sys,subprocess
from pathlib import Path
inp=json.load(sys.stdin)
p=Path('calls.jsonl')
n=len(p.read_text().splitlines())+1 if p.exists() else 1
mode=Path('mode').read_text()
results=[]
for target in ['check','live']:
 r=subprocess.run(['make',target],capture_output=True,text=True)
 results.append({'target':target,'exit':r.returncode,'output':r.stdout+r.stderr})
 if r.returncode: break
failed=results[-1]['exit']!=0
out=({'continue':False,'stopReason':'Verification exhausted at third failure'} if n>=3 else {'decision':'block','reason':'Fixture verification failed. Do not use tools or change files. Reply OK again.'}) if failed else {'continue':True}
with p.open('a') as f:f.write(json.dumps({'n':n,'input':inp,'targets':results,'response':out})+'\\n')
print(json.dumps(out))
'''
results=[]
for mode in ['exhaust','pass-third']:
 root=base/('native-'+mode)
 root.mkdir(exist_ok=False);(root/'.codex').mkdir()
 (root/'probe_hook.py').write_text(hook)
 (root/'mode').write_text(mode)
 (root/'Makefile').write_text('.PHONY: check live\ncheck:\n\t@echo check\nlive:\n\t@python3 gate.py\n')
 (root/'gate.py').write_text("from pathlib import Path\nimport sys\np=Path('gate-count'); n=int(p.read_text())+1 if p.exists() else 1; p.write_text(str(n)); print('live',n); sys.exit(0 if Path('mode').read_text()=='pass-third' and n==3 else 1)\n")
 (root/'.codex/hooks.json').write_text(json.dumps({'hooks':{'Stop':[{'hooks':[{'type':'command','command':'python3 '+shlex.quote(str(root/'probe_hook.py')),'timeout':30}]}]}}))
 subprocess.run(['git','init','-q',str(root)],check=True)
 args=['codex','exec','--ephemeral','--json','--enable','hooks','--dangerously-bypass-hook-trust','--dangerously-bypass-approvals-and-sandbox','-m','gpt-5.6-sol','-c','model_reasoning_effort="low"','Reply only OK. Do not use tools, read files, or edit anything. If a Stop hook requests another reply, reply OK again.']
 start=time.monotonic()
 with (root/'stdout.jsonl').open('w') as out,(root/'stderr.txt').open('w') as err:
  proc=subprocess.Popen(args,cwd=root,stdout=out,stderr=err,start_new_session=True,env={**os.environ,'KOGEN_ROLE':'probe'})
  try:code=proc.wait(timeout=150)
  except subprocess.TimeoutExpired:
   os.killpg(proc.pid,signal.SIGTERM);code=proc.wait(timeout=10)
 calls=[json.loads(x) for x in (root/'calls.jsonl').read_text().splitlines()] if (root/'calls.jsonl').exists() else []
 events=[json.loads(x) for x in (root/'stdout.jsonl').read_text().splitlines() if x.startswith('{')]
 result={'mode':mode,'argv':args,'exit':code,'elapsed':round(time.monotonic()-start,2),'calls':len(calls),'responses':[c['response'] for c in calls],'event_types':[e.get('type') for e in events],'source_sha256':hashlib.sha256((root/'probe_hook.py').read_bytes()).hexdigest()}
 results.append(result); print(json.dumps(result),flush=True)
 # Remove only generated Git metadata; all probe inputs and receipts remain.
 import shutil
 shutil.rmtree(root/'.git')
(base/'native-probe-summary.json').write_text(json.dumps({'cli':subprocess.check_output(['codex','--version'],text=True).strip(),'results':results},indent=2)+'\n')
