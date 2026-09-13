#!/usr/bin/env python3
"""Capture public Shape dispatch with small/large on-disk context, fake provider only."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
RUN = Path(json.loads(Path(os.environ.get('ROLE_CONTEXT_PROBE_LOCATION', str(HERE / 'probe-location.json'))).read_text())['run'])
ENGINE = RUN / 'engine'
LOG = RUN / 'shape-dispatch'
LOG.mkdir(exist_ok=False)
FAKE = LOG / 'fake-shaper.py'
FAKE.write_text('''#!/usr/bin/env python3
import hashlib,json,os,pathlib,re,sys
prompt=sys.argv[-1]
match=re.search(r'Draft directory: `([^`]+)`',prompt)
source=pathlib.Path(match[1])/'INTENT.md' if match else pathlib.Path('README.md')
content=source.read_bytes()
pathlib.Path(os.environ['SHAPE_PROBE_OUTPUT']).write_text(json.dumps({'prompt':prompt,'read_path':str(source),'read_bytes':len(content),'read_sha256':hashlib.sha256(content).hexdigest()}))
''')
FAKE.chmod(0o755)
DRAFT = ENGINE / '.kogen/intents/drafts/context-shape-proof'
DRAFT.mkdir(parents=True, exist_ok=False)
(DRAFT / 'intent.yaml').write_text('''id: 01960000-0000-7000-8000-00000000aa13
slug: context-shape-proof
shaped_against:
  branch: main
  head: baseline
shaping:
  harness: codex
  model: fixture-original
  effort: low
  started: '2026-01-01T00:00:00Z'
''')
readme = ENGINE / 'README.md'
original = readme.read_bytes()
summary = []
try:
    for route, args, source in [('fresh', [], readme), ('continued', ['context-shape-proof'], DRAFT / 'INTENT.md')]:
        captures = []
        for label, n in [('small', 1), ('large', 45000)]:
            source.write_text('SHAPE_CONTEXT_SENTINEL' * n)
            out = LOG / f'{route}-{label}.json'
            env = dict(os.environ, KOGEN_HARNESS=str(FAKE), SHAPE_PROBE_OUTPUT=str(out))
            for key in ['MIX_BUILD_PATH', 'MIX_ENV']: env.pop(key, None)
            result = subprocess.run(['mix', 'kogen.shape'] + args, cwd=ENGINE, env=env, capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
            capture = json.loads(out.read_text())
            assert 'SHAPE_CONTEXT_SENTINEL' not in capture['prompt']
            # Only minted identity and visit timestamp change between calls.
            normalized = re.sub(r'[0-9a-f]{8}-[0-9a-f-]{27}', '<UUID>', capture['prompt'])
            normalized = re.sub(r'2026-\d\d-\d\dT[0-9:.]+Z', '<TIME>', normalized)
            captures.append((capture, normalized))
        assert captures[0][1] == captures[1][1]
        assert captures[0][0]['read_sha256'] != captures[1][0]['read_sha256']
        summary.append({'route': route, 'prompt_bytes': [len(c[0]['prompt'].encode()) for c in captures], 'source_read_bytes': [c[0]['read_bytes'] for c in captures], 'normalized_prompt_unchanged': True})
finally:
    readme.write_bytes(original)
(LOG / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
print(json.dumps(summary))
