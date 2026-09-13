#!/usr/bin/env python3
"""Hold source fixed and change linked requirement through the actual fake provider."""
import json
import os
from pathlib import Path
import subprocess
import sys
HERE = Path(__file__).resolve().parent
RUN = Path(json.loads(Path(os.environ.get('ROLE_CONTEXT_PROBE_LOCATION', str(HERE / 'probe-location.json'))).read_text())['run'])
DEST = RUN / 'linked-oracle-controls'
DEST.mkdir(exist_ok=False)
results = []
for name, expected in [('matching', 'ready'), ('changed-requirement', 'different')]:
    case = DEST / name
    work = case / 'worktree'
    approved = work / '.kogen/intents/approved/oracle'
    approved.mkdir(parents=True)
    (approved/'requirement.json').write_text(json.dumps({'path':'probe-value.txt','expected':expected}))
    (work/'probe-value.txt').write_text('ready\n')
    source = work/'lib/kogen/build.ex'
    source.parent.mkdir(parents=True)
    source.write_bytes((RUN/'candidate/lib/kogen/build.ex').read_bytes())
    record = work/'.kogen/runtime/record.json'
    record.parent.mkdir(parents=True)
    record.write_text(json.dumps({'scenarios':[{'id':'one'}], 'attempts':[{'attempt_token':'current','candidate_id':'candidate'}], 'findings':[]}))
    packet={'tracking_path':'.kogen/runtime/record.json','approved_path':'.kogen/intents/approved/oracle','attempt_token':'current','candidate_id':'candidate'}
    output=case/'verdict.json'
    env=dict(os.environ, ROLE_CONTEXT_PROBE_RUN=str(case),ROLE_CONTEXT_PROBE_PHASE='prototype-engine',ROLE_CONTEXT_PROBE_SLUG='oracle')
    proc=subprocess.run([sys.executable,str(HERE/'bootstrap-provider.py'),'--output-schema','fixture-schema','--output-last-message',str(output)],cwd=work,env=env,input='KOGEN_TASK_CONTEXT\n'+json.dumps(packet),text=True,capture_output=True)
    assert proc.returncode==0,proc.stderr
    verdict=json.loads(output.read_text())['verdict']
    assert verdict==('accept' if name=='matching' else 'rework')
    results.append({'case':name,'source_value':'ready','linked_expected':expected,'verdict':verdict})
(DEST/'summary.json').write_text(json.dumps(results,indent=2)+'\n')
print(json.dumps(results))
