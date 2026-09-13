#!/usr/bin/env python3
"""Negative controls for the prototype's actual fixture reader; no gate invocation."""
import importlib.util
import json
import os
from pathlib import Path
import sys
sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
RUN = Path(json.loads(Path(os.environ.get('ROLE_CONTEXT_PROBE_LOCATION', str(HERE / 'probe-location.json'))).read_text())['run'])
DEST = RUN / 'reader-controls'
DEST.mkdir(exist_ok=False)
spec = importlib.util.spec_from_file_location('reader', RUN / 'candidate/test/support/scenario_response.py')
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
record = DEST / 'record.json'
record.write_text(json.dumps({'attempts': [{'attempt_token': 'current', 'candidate_id': 'candidate'}], 'scenarios': [{'id': 'actual-source-id', 'then': 'actual requirement'}], 'findings': []}))
packet = {'tracking_path': str(record), 'attempt_token': 'current', 'candidate_id': 'candidate'}
results = []
for name, fields in [('valid', {}), ('stale-attempt', {'attempt_token': 'stale'}), ('wrong-candidate', {'candidate_id': 'wrong'}), ('missing-record', {'tracking_path': str(DEST/'missing.json')})]:
    prompt = 'KOGEN_TASK_CONTEXT\n' + json.dumps(packet | fields)
    try:
        value = reader.snapshot(prompt)
        assert name == 'valid', f'{name} unexpectedly succeeded'
        assert value['scenarios'][0]['id'] == 'actual-source-id'
        results.append({'case': name, 'result': 'read actual record'})
    except ValueError as error:
        assert name != 'valid'
        results.append({'case': name, 'result': 'rejected', 'reason': str(error)})
record.write_text('{malformed')
try:
    reader.snapshot('KOGEN_TASK_CONTEXT\n' + json.dumps(packet))
    raise AssertionError('malformed record unexpectedly succeeded')
except ValueError as error:
    results.append({'case': 'malformed-record', 'result': 'rejected', 'reason': str(error)})
(DEST / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results))
