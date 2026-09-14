import json,pathlib,sys
p=pathlib.Path(__file__).parent/'stops.jsonl'
v=json.load(sys.stdin)
prior=p.read_text().splitlines() if p.exists() else []
with p.open('a') as f:f.write(json.dumps(v)+'\n')
print(json.dumps({'decision':'block','reason':'Probe Stop control: continue in the same session and finish again. Do not use tools.'} if not prior else {}))
