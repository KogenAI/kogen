import os,json,subprocess,tempfile,shutil,hashlib,importlib.util
from pathlib import Path
root=Path.cwd();out=Path(__file__).resolve().parent
results={'provider_calls':0,'production_writes':0,'source_sha256':{}}
for name in ['.codex/hooks/check.sh','.codex/hooks/environment.py','test/support/shaping_evaluation/driver.py']:
 results['source_sha256'][name]=hashlib.sha256((root/name).read_bytes()).hexdigest()
with tempfile.TemporaryDirectory(dir=out,prefix='owned-') as tmp:
 p=Path(tmp);shutil.copy(root/'.codex/hooks/check.sh',p/'check.sh')
 env={**os.environ,'KOGEN_ROLE':'reviewer','KOGEN_ENV_RESTORE_PENDING':'1'}
 a=subprocess.run(['sh',str(p/'check.sh')],input='',env=env,text=True,capture_output=True,timeout=5)
 shutil.copy(root/'.codex/hooks/environment.py',p/'environment.py')
 b=subprocess.run(['sh',str(p/'check.sh')],input='',env=env,text=True,capture_output=True,timeout=5)
 results['hook_missing_dependency']={'exit':a.returncode,'missing_file_error':'environment.py' in a.stderr and 'No such file' in a.stderr}
 results['hook_complete_dependency']={'exit':b.returncode,'output':b.stdout.strip()}
 assert a.returncode!=0 and b.returncode==0
os.environ['KOGEN_SHAPING_EVALUATION_RUNTIME']=str(root/'.kogen/runtime/shaping-evaluation-1789333004295-578')
s=importlib.util.spec_from_file_location('driver',root/'test/support/shaping_evaluation/driver.py');d=importlib.util.module_from_spec(s);s.loader.exec_module(d)
module=d.integrity_module();results['source_sha256'][str(Path(module.__file__).relative_to(root))]=hashlib.sha256(Path(module.__file__).read_bytes()).hexdigest()
run=Path(os.environ['KOGEN_SHAPING_EVALUATION_RUNTIME'])/'runs/csv-continuation'
ctx=json.loads((run/'managed-launch-context.json').read_text());sessions=Path(dict(ctx['env'])['CODEX_HOME'])/'sessions'
f=next(sessions.rglob('*01a09c8f-48e6-7a53-a907-428433fe6bbb*.jsonl'));rows=[json.loads(l) for l in f.open()];submitted=[{'text':(run/'resume-0.txt').read_text()}]
try:module.ordered_turn_bindings(rows,submitted);raise AssertionError('Expected rejection')
except ValueError as e:results['actual_correlation_error']=str(e)
def environment_update(x):
 p=x.get('payload',{});return p.get('role')=='user' and ''.join(c.get('text','') for c in p.get('content',[]) if isinstance(c,dict)).startswith('<environment_context>')
control=[x for x in rows if not environment_update(x)]
results['synthetic_without_environment_updates']=module.ordered_turn_bindings(control,submitted)
assert results['synthetic_without_environment_updates']
results['limitations']='No native invocation. Removing environment messages is a diagnostic control, not an approved filtering algorithm. Hook probe uses Reviewer role and never runs Check. No raw conversation copied.'
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(results,indent=2))
