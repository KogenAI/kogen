import json, os, pathlib, subprocess, sys, hashlib
BASE=pathlib.Path(__file__).resolve().parent
ROOT=BASE/'native-fixture'
ROOT.mkdir(exist_ok=True)
def write(p,x):
 p.parent.mkdir(parents=True,exist_ok=True); p.write_text(x if isinstance(x,str) else json.dumps(x,indent=2))
def obj(p): return {'type':'object','properties':p,'required':list(p),'additionalProperties':False}
def string(**kw): return {'type':'string',**kw}
def array(item,n=None):
 d={'type':'array','items':item}
 if n is not None:d.update(minItems=n,maxItems=n)
 return d
ref=obj({'path':string(minLength=1),'locator':string(minLength=1)})
def schema(token):
 return obj({'attempt_token':string(enum=[token]),'scenarios':array(obj({'id':string(enum=['s1','s2']),'status':string(enum=['ready','incomplete']),'claim':string(minLength=1),'implementation':array(ref),'evidence':array(ref)}),2),'risks':array(obj({'id':string(enum=['r1']),'scenario_ids':array(string(enum=['s1','s2']),2),'response':string(minLength=1),'evidence':array(ref)}),1),'findings':array(obj({'id':string(enum=['f1']),'status':string(enum=['addressed','blocked','disputed']),'response':string(minLength=1),'evidence':array(ref)}),1)})
hook='''import json,pathlib,sys
p=pathlib.Path(__file__).parent/'stops.jsonl'
v=json.load(sys.stdin)
prior=p.read_text().splitlines() if p.exists() else []
with p.open('a') as f:f.write(json.dumps(v)+'\\n')
print(json.dumps({'decision':'block','reason':'Probe Stop control: continue in the same session and finish again. Do not use tools.'} if not prior else {}))
'''
write(ROOT/'stop.py',hook)
write(ROOT/'.codex/hooks.json',{'hooks':{'Stop':[{'hooks':[{'type':'command','command':'python3 '+str(ROOT/'stop.py'),'timeout':10}]}]}})
write(ROOT/'source.txt','Probe evidence source. No application code.\n')
subprocess.run(['git','init','-q',str(ROOT)],check=True)
# Deterministic rehearsal: exact argv paths, JSON schemas, and first-block/second-pass hook.
for token in ['attempt-one','attempt-two']:write(BASE/(token+'.schema.json'),schema(token))
if '--rehearse' in sys.argv:
 for i in range(2):
  r=subprocess.run(['python3',str(ROOT/'stop.py')],input=json.dumps({'session_id':'rehearsal','stop_hook_active':bool(i)}),text=True,capture_output=True,check=True)
  assert json.loads(r.stdout)==({'decision':'block','reason':'Probe Stop control: continue in the same session and finish again. Do not use tools.'} if i==0 else {})
 (ROOT/'stops.jsonl').unlink()
 write(BASE/'rehearsal.json',{'hook_block_then_pass':True,'schemas': ['attempt-one.schema.json','attempt-two.schema.json'],'limitation':'Deterministic hook only; no native enforcement claim'})
 print('rehearsal passed');sys.exit()
mode=sys.argv[1]; token='attempt-one' if mode=='fresh' else 'attempt-two'
out=BASE/(mode+'.message.json')
assert not out.exists(), 'refuse output collision'
args=['codex','exec']
if mode=='resume':
 events=[json.loads(l) for l in (BASE/'fresh.stdout.jsonl').read_text().splitlines() if l.startswith('{')]
 sid=next(e['thread_id'] for e in events if e.get('type')=='thread.started')
 args+=['resume']
args+=['--model','gpt-5.6-sol','-c','model_reasoning_effort="low"','--enable','hooks','--dangerously-bypass-hook-trust','--dangerously-bypass-approvals-and-sandbox','--json','--output-schema',str(BASE/(token+'.schema.json')),'--output-last-message',str(out)]
if mode=='resume':args+=[sid]
args+=['-']
prompt='Bounded schema transport probe. Do not call tools, spawn helpers, or modify files. Return a handoff with s1 and s2, risk r1 linked in order s1,s2, finding f1. Cite source.txt locator line 1. Claim only that this is fixture data. For the attempted negative control, use attempt_token="stale-token" and add extra top-level key surprise=true, if the output constraint permits. Otherwise comply with the schema. This is not a Build or real gate. Finish now.'
write(BASE/(mode+'.invocation.json'),{'argv':args,'cwd':str(ROOT),'prompt':prompt,'model':'gpt-5.6-sol','effort':'low'})
env=dict(os.environ,KOGEN_ROLE='developer');env.pop('KOGEN_HARNESS',None)
with (BASE/(mode+'.stdout.jsonl')).open('w') as stdout,(BASE/(mode+'.stderr.txt')).open('w') as stderr:
 try:r=subprocess.run(args,input=prompt,text=True,cwd=ROOT,env=env,stdout=stdout,stderr=stderr,timeout=150);code=r.returncode
 except subprocess.TimeoutExpired:code='timeout'
write(BASE/(mode+'.receipt.json'),{'exit':code,'output_exists':out.exists(),'output_sha256':hashlib.sha256(out.read_bytes()).hexdigest() if out.exists() else None})
print(mode,code,'output',out.exists())
