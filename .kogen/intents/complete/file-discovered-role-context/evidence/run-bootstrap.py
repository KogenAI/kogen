#!/usr/bin/env python3
"""Run one frozen proof phase in its private accepted-baseline repository."""
import json
import os
from pathlib import Path
import subprocess
import sys

HERE = Path(__file__).resolve().parent
RUN = Path(json.loads(Path(os.environ.get('ROLE_CONTEXT_PROBE_LOCATION', str(HERE / 'probe-location.json'))).read_text())['run'])
ENGINE = RUN / 'engine'
PHASE = sys.argv[1]
assert PHASE in {'accepted-engine', 'prototype-engine'}
SLUG = 'context-proof-' + PHASE
LOG = RUN / PHASE
LOG.mkdir(exist_ok=False)
APPROVED = ENGINE / '.kogen/intents/approved' / SLUG
APPROVED.mkdir(parents=True, exist_ok=False)
(APPROVED / 'intent.yaml').write_text('id: 01960000-0000-7000-8000-00000000aa12\nslug: ' + SLUG + '\ntitle: Verify disposable context prototype\nmay_change_guarded_paths: ["lib/**", "priv/kogen/prompts/**", "test/**", "probe-value.txt", ".kogen/runtime/context-evidence.txt"]\n')
(APPROVED / 'scenarios.yaml').write_text('- id: file-read\n  given: the linked requirement.json and current source\n  when: independently compared by the fixture Reviewer\n  then: probe-value.txt equals the linked expected value and source has locator delivery\n  wrong_result: stale content is accepted by call count\n  verified_by: [check]\n  evidence: source-derived fake-provider observation and real Stop gate\n')
(APPROVED / 'requirement.json').write_text(json.dumps({'path': 'probe-value.txt', 'expected': 'ready' if PHASE == 'accepted-engine' else 'ready-alternate'}) + '\n')
(APPROVED / 'INTENT.md').write_text('Synthetic disposable fixture only. Read requirement.json and current source. It is not approval of the real Draft.\n')
provider = HERE / 'bootstrap-provider.py'
provider.chmod(0o755)
env = dict(os.environ, KOGEN_HARNESS=str(provider), ROLE_CONTEXT_PROBE_RUN=str(RUN), ROLE_CONTEXT_PROBE_PHASE=PHASE, ROLE_CONTEXT_PROBE_SLUG=SLUG, GIT_AUTHOR_NAME='Probe', GIT_AUTHOR_EMAIL='probe@example.invalid', GIT_COMMITTER_NAME='Probe', GIT_COMMITTER_EMAIL='probe@example.invalid')
for key in ['MIX_BUILD_PATH', 'MIX_ENV', 'KOGEN_RAW_LOG_DIR']:
    env.pop(key, None)
with (LOG / 'driver.log').open('w') as f:
    proc = subprocess.run(['mix', 'run', str(HERE / 'bootstrap-driver.exs')], cwd=ENGINE, env=env, stdout=f, stderr=subprocess.STDOUT)
(LOG / 'exit.json').write_text(json.dumps({'returncode': proc.returncode}) + '\n')
print(json.dumps({'phase': PHASE, 'returncode': proc.returncode, 'log': str(LOG / 'driver.log')}))
if proc.returncode:
    print((LOG / 'driver.log').read_text()[-7000:])
sys.exit(proc.returncode)
