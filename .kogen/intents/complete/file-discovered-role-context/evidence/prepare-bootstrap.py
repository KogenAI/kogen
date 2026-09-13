#!/usr/bin/env python3
"""Prepare unique private copies for this bounded frozen-baseline proof."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
LOCATION = Path(os.environ.get('ROLE_CONTEXT_PROBE_LOCATION', str(HERE / 'probe-location.json')))
if LOCATION.exists():
    raise SystemExit('Choose a new ROLE_CONTEXT_PROBE_LOCATION; existing evidence is preserved.')
HEAD = '1843dcfaf8b0b7c9d9f91d5c3e8ca92f41633fcb'
RUN = Path(tempfile.mkdtemp(prefix='kogen-role-context-proof-'))
archive = subprocess.check_output(['git', 'archive', HEAD], cwd=ROOT)
for name in ['candidate', 'engine']:
    dest = RUN / name
    dest.mkdir()
    with tarfile.open(fileobj=io.BytesIO(archive)) as bundle:
        bundle.extractall(dest)
    for directory in ['deps', '_build']:
        if (ROOT / directory).exists():
            shutil.copytree(ROOT / directory, dest / directory)
    for args in [['init', '-q', '-b', 'main'], ['add', '-A'], ['-c', 'user.name=Probe', '-c', 'user.email=probe@example.invalid', 'commit', '-qm', 'Frozen accepted baseline']]:
        subprocess.run(['git'] + args, cwd=dest, check=True)
subprocess.run(['git', 'apply', str(HERE / 'prototype.patch')], cwd=RUN / 'candidate', check=True)
paths = subprocess.check_output(['git', 'diff', '--name-only'], cwd=RUN / 'candidate', text=True).splitlines()
(RUN / 'prototype-paths.json').write_text(json.dumps(paths, indent=2) + '\n')
LOCATION.write_text(json.dumps({'run': str(RUN), 'candidate': str(RUN / 'candidate'), 'engine': str(RUN / 'engine')}, indent=2) + '\n')
print(LOCATION)
