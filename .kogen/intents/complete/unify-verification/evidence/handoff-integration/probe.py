from pathlib import Path
import json,subprocess,os,sys,hashlib,shlex,time,signal,shutil
base=Path(__file__).resolve().parent
repo=Path.cwd().resolve()
hook='''import json,sys,subprocess
from pathlib import Path
inp=json.load(sys.stdin); p=Path('stops.jsonl'); n=len(p.read_text().splitlines())+1 if p.exists() else 1
results=[]
for target in ['check','live']:
 r=subprocess.run(['make',target],capture_output=True,text=True);results.append({'target':target,'exit':r.returncode})
 if r.returncode:break
failed=results[-1]['exit']!=0
out=({'continue':False,'stopReason':'Verification exhausted'} if n==3 else {'decision':'block','reason':'Fixture target failed; return the same structured handoff again, without tools.'}) if failed else {'continue':True}
with p.open('a') as f:f.write(json.dumps({'number':n,'input':inp,'targets':results,'response':out})+'\\n')
print(json.dumps(out))
'''
mode=sys.argv[1]
root=base/mode;root.mkdir();(root/'.codex').mkdir();(root/'tmp').mkdir()
(root/'stop.py').write_text(hook);(root/'source.txt').write_text('Source-owned probe reference.\n')
(root/'Makefile').write_text('.PHONY: check live\ncheck:\n\t@true\nlive:\n\t@python3 gate.py\n')
(root/'gate.py').write_text("from pathlib import Path\nimport sys\np=Path('gate-count'); n=int(p.read_text())+1 if p.exists() else 1;p.write_text(str(n));sys.exit(0 if "+repr(mode.endswith('pass'))+" and n==3 else 1)\n")
(root/'.codex/hooks.json').write_text(json.dumps({'hooks':{'Stop':[{'hooks':[{'type':'command','command':'python3 '+shlex.quote(str(root/'stop.py')),'timeout':30}]}]}}))
subprocess.run(['git','init','-q',str(root)],check=True)
env={**os.environ,'TMPDIR':str(root/'tmp')}
if mode.startswith('rehearsal'):
 fake=root/'fake-codex';fake.write_text('''#!/usr/bin/env python3
import sys,json,subprocess
from pathlib import Path
args=sys.argv;out=Path(args[args.index('--output-last-message')+1]);sys.stdin.read()
for n in range(4):
 r=subprocess.run(['python3','stop.py'],input=json.dumps({'session_id':'fake-dev','turn_id':'fake-turn','hook_event_name':'Stop'}),capture_output=True,text=True,check=True)
 reply=json.loads(r.stdout)
 if reply.get('decision')!='block':break
else:raise AssertionError('Fourth callback')
out.write_text(json.dumps({'attempt_token':'probe-token','scenarios':[{'id':'s1','status':'ready','claim':'The probe source exists','implementation':[{'path':'source.txt','locator':'line 1'}],'evidence':[{'path':'source.txt','locator':'line 1'}]}],'risks':[],'findings':[]}))
print(json.dumps({'type':'thread.started','thread_id':'fake-dev'}));print(json.dumps({'type':'turn.completed'}))
''');fake.chmod(0o755);env['KOGEN_HARNESS']=str(fake)
else:env.pop('KOGEN_HARNESS',None)
args=['elixir']
for d in sorted((repo/'_build/dev/lib').glob('*/ebin')):args+=['-pa',str(d)]
args+=[str(base/'consumer.exs'),str(repo),str(root),mode]
t=time.monotonic()
with (root/'stdout.txt').open('w') as out,(root/'stderr.txt').open('w') as err:
 proc=subprocess.Popen(args,env=env,stdout=out,stderr=err,start_new_session=True)
 try:code=proc.wait(timeout=150)
 except subprocess.TimeoutExpired:
  os.killpg(proc.pid,signal.SIGTERM);code=proc.wait(timeout=10)
r={'argv':args,'exit':code,'elapsed':time.monotonic()-t,'head':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),'source_hashes':{f:hashlib.sha256((repo/f).read_bytes()).hexdigest() for f in ['lib/kogen/harness.ex','lib/kogen/build/developer_handoff.ex','lib/kogen/build/contract.ex']},'cli':subprocess.check_output(['codex','--version'],text=True).strip()}
(root/'command.json').write_text(json.dumps(r,indent=2)+'\n')
shutil.rmtree(root/'.git')
print(mode,code)
print((root/'consumer-summary.json').read_text() if (root/'consumer-summary.json').exists() else (root/'stderr.txt').read_text()[-1800:])
if code:sys.exit(code)
calls=[json.loads(x) for x in (root/'stops.jsonl').read_text().splitlines()]
assert len(calls)==3,calls
assert calls[-1]['response']['continue']==mode.endswith('pass')
