import json,sys,subprocess
from pathlib import Path
inp=json.load(sys.stdin); p=Path('stops.jsonl'); n=len(p.read_text().splitlines())+1 if p.exists() else 1
results=[]
for target in ['check','live']:
 r=subprocess.run(['make',target],capture_output=True,text=True);results.append({'target':target,'exit':r.returncode})
 if r.returncode:break
failed=results[-1]['exit']!=0
out=({'continue':False,'stopReason':'Verification exhausted'} if n==3 else {'decision':'block','reason':'Fixture target failed; return the same structured handoff again, without tools.'}) if failed else {'continue':True}
with p.open('a') as f:f.write(json.dumps({'number':n,'input':inp,'targets':results,'response':out})+'\n')
print(json.dumps(out))
