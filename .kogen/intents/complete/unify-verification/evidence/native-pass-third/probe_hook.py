import json,sys,subprocess
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
with p.open('a') as f:f.write(json.dumps({'n':n,'input':inp,'targets':results,'response':out})+'\n')
print(json.dumps(out))
