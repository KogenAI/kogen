import json,os,subprocess,tempfile,hashlib
from pathlib import Path
out=Path(__file__).resolve().parent
source=Path('.kogen/runtime/shaping-evaluation-1789333004295-578/runs/csv-continuation/managed-launch-context.json')
c=json.loads(source.read_text());env=os.environ.copy()
for k,v in c['env']:
 if v is None:env.pop(k,None)
 else:env[k]=v
env.pop('KOGEN_CODEX_CONTEXT_RECEIPT',None);env['KOGEN_ROLE']='reviewer'
prompt='''Bounded native capability probe, explicitly authorized delegation. Do not read files, use shell, modify anything, or run gates. Inspect the actual spawn_agent tool schema. If it has no agent_type parameter, do not spawn; return JSON {"agent_type_available":false}. If it has agent_type, spawn exactly three fresh children with fork_turns none: scout_probe explorer gpt-5.6-luna low; worker_probe worker gpt-5.6-luna medium; expert_probe default gpt-5.6-sol medium. Each message: "Do not use tools or delegate. Return exactly OK." Wait for their results; report the requested kinds and completion. Never omit or invent an unsupported argument.'''
with tempfile.TemporaryDirectory(dir=out,prefix='native-owned-') as t:
 cmd=[c['executable'],*c['args'],'exec','--skip-git-repo-check','--json','-m','gpt-5.6-sol','-c','model_reasoning_effort="low"','--dangerously-bypass-approvals-and-sandbox','-C',t,prompt]
 try:r=subprocess.run(cmd,env=env,input='',text=True,capture_output=True,timeout=100);stdout=r.stdout;status=r.returncode
 except subprocess.TimeoutExpired as e:stdout=e.stdout or b'';stdout=stdout.decode() if isinstance(stdout,bytes) else stdout;status='timeout'
 rows=[]
 for l in stdout.splitlines():
  try:rows.append(json.loads(l))
  except ValueError:pass
 ids=[x.get('thread_id') for x in rows if x.get('type')=='thread.started'];summary={'exit':status,'context_source':str(source),'binary_sha256':hashlib.sha256(Path(c['executable']).read_bytes()).hexdigest(),'events':[x.get('type') for x in rows],'answers':[x['item'].get('text') for x in rows if x.get('item',{}).get('type')=='agent_message'],'native_calls':[]}
 for id in ids:
  for f in (Path(env['CODEX_HOME'])/'sessions').rglob('*'+id+'*.jsonl'):
   for l in f.open():
    x=json.loads(l);p=x.get('payload',{})
    if p.get('type')=='function_call' and p.get('name')=='spawn_agent':
     a=json.loads(p['arguments']);summary['native_calls'].append({k:v for k,v in a.items() if k not in ['message','prompt']})
(out/'native-results.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
