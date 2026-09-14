from pathlib import Path
import json,subprocess,os,shutil,hashlib
base=Path(__file__).resolve().parent
results=[]
for case in ['pass-control','corrupt-after-two','delete-after-two','intact-exhausted','delete-exhausted']:
 root=base/case;root.mkdir();runtime=root/'.kogen/runtime';runtime.mkdir(parents=True);(runtime/'tmp').mkdir()
 shutil.copyfile(base/'candidate-source.py',root/'runner.py')
 (root/'.gitignore').write_text('.kogen/runtime/\n')
 (root/'Makefile').write_text('check:\n\t@echo dispatch >> .kogen/runtime/dispatch.log\n\t@test -f .kogen/runtime/pass\n')
 subprocess.run(['git','init','-q',str(root)],check=True);subprocess.run(['git','add','.'],cwd=root,check=True)
 state=runtime/'state.json';context=runtime/'context.json'
 context.write_text(json.dumps({'schema_version':1,'mode':'unified','build_id':'probe','outer_attempt':0,'attempt_token':'probe-token','project_root':str(root),'targets':['check'],'verification_retries':2,'state_path':str(state),'log_root':str(runtime/'logs')}))
 env={**os.environ,'KOGEN_VERIFICATION_CONTEXT':str(context),'KOGEN_ROLE':'developer','TMPDIR':str(runtime/'tmp')}
 calls=[]
 def invoke():
  r=subprocess.run(['python3','runner.py'],cwd=root,env=env,input=json.dumps({'session_id':'probe-developer','hook_event_name':'Stop'}),capture_output=True,text=True,timeout=20)
  calls.append({'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr,'state':state.read_text() if state.exists() else None,'dispatch_count':len((runtime/'dispatch.log').read_text().splitlines())})
 for _ in range(1 if case=='pass-control' else 3 if 'exhausted' in case else 2):invoke()
 before=calls[-1]['dispatch_count']
 if case=='pass-control':(runtime/'pass').write_text('pass')
 elif case.startswith('corrupt'):state.write_text('{')
 elif case.startswith('delete'):state.unlink()
 invoke()
 (root/'receipt.json').write_text(json.dumps(calls,indent=2)+'\n')
 last=json.loads(calls[-1]['state']);result={'case':case,'dispatch_before':before,'dispatch_after':calls[-1]['dispatch_count'],'extra_dispatch':calls[-1]['dispatch_count']-before,'failures_after':last['failures_since_pass'],'cycles_after':len(last['cycles']),'terminal_after':last['terminal_state'],'response':json.loads(calls[-1]['stdout'])}
 results.append(result)
 shutil.rmtree(root/'.git')
(base/'probe-results.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results,indent=2))
