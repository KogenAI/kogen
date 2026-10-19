#!/usr/bin/env python3
"""Repeat native rendering, no model/transport. See README.md for retained inputs."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[3]
qualification, destination = map(lambda p: Path(p).resolve(), sys.argv[1:])
destination.mkdir(parents=True, exist_ok=False)
frozen = json.loads((qualification / 'frozen-inputs.json').read_bytes())
corpus = Path(frozen['corpus'])
request = qualification / 'captured-kogen031-request.txt'
sha = lambda b: hashlib.sha256(b).hexdigest()
assert sha(request.read_bytes()) == frozen['request_sha256']
for entry in frozen['manifest']:
    data = (corpus / entry['path']).read_bytes()
    assert sha(data) == entry['sha256'] and len(data) == entry['bytes']
old = destination / 'before-source'
old.mkdir()
subprocess.run(['git', 'archive', 'b2c9876b27a99d19a82564821879dc42e83b03c1', '-o', str(destination / 'old.tar')], cwd=repo, check=True)
subprocess.run(['tar', '-xf', str(destination / 'old.tar'), '-C', str(old)], check=True)
(destination / 'old.tar').unlink()
(request_copy := destination / request.name).write_bytes(request.read_bytes())
(destination / 'frozen-inputs.json').write_bytes((qualification / 'frozen-inputs.json').read_bytes())
receipts = {}
for arm, source in [('before', old), ('after', repo)]:
    env = dict(os.environ, ERL_FLAGS='+S 2:2', QUAL_CORPUS=str(corpus), QUAL_SOURCE=str(source), QUAL_INSTALL_ROOT=str(repo), QUAL_REQUEST=str(request_copy))
    adapter = str(Path(__file__).with_name('render.exs'))
    expression = 'for n <- 1..2 do System.put_env("QUAL_OUTPUT", ' + json.dumps(str(destination / arm)) + ' <> "-" <> Integer.to_string(n)); Code.eval_file(' + json.dumps(adapter) + ') end'
    with (destination / f'{arm}.log').open('wb') as log:
        subprocess.run(['mix', 'run', '-e', expression], cwd=repo, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    for extension in ('json', 'context.txt', 'input.json', 'provider.json', 'index.json'):
        assert (destination / f'{arm}-1.{extension}').read_bytes() == (destination / f'{arm}-2.{extension}').read_bytes(), (arm, extension)
    receipts[arm] = json.loads((destination / f'{arm}-1.json').read_bytes())
b, a = receipts['before'], receipts['after']
indexes = {arm: json.loads((destination / f'{arm}-1.index.json').read_bytes()) for arm in receipts}
assert indexes['before']['revision'] == indexes['after']['revision'] == {'head': 'b2c9876b27a99d19a82564821879dc42e83b03c1', 'tree': '11c0fae04a2720a1b1f45a250b15fce366c612a8'}
assert indexes['before']['directories'] == indexes['after']['directories']
fields = ('path', 'sha256', 'bytes', 'ownership', 'signatures', 'signature_index')
assert [{k: e.get(k) for k in fields} for e in indexes['before']['entries']] == [{k: e.get(k) for k in fields} for e in indexes['after']['entries']]
for key in ('request_sha256', 'tools_sha256', 'instructions_sha256', 'provider_serializer_source_sha256'):
    assert b[key] == a[key], key
assert all(a['required_input_checks'].values()) and all(b['required_input_checks'].values())
metrics = ('rendered_context_bytes', 'serialized_input_bytes', 'full_provider_request_bytes', 'index_json_bytes', 'excerpt_header_count', 'excerpt_header_bytes')
selection = {}
for arm, receipt in receipts.items():
    context = (destination / f'{arm}-1.context.txt').read_text()
    headers = [json.loads(line[len('Excerpt: '):]) for line in context.splitlines() if line.startswith('Excerpt: ')]
    optional = [e for e in receipt['body_measurement']['selection'] if e['path'] != 'README.md' and e['included_body_bytes']]
    selection[arm] = dict(bytes=receipt['optional_body_bytes'], static_selection_body_bytes=sum(e['included_body_bytes'] for e in optional), count=len(optional), paths=[e['path'] for e in optional], ranges=[{k: h[k] for k in ('path', 'start_line', 'end_line')} for h in headers])
assert selection['after']['bytes'] == selection['after']['count'] == 0
report = dict(scope='Fresh deterministic initial rendering, exact retained KOGEN031 capture; no live model or transport', capture_sha256=sha(request_copy.read_bytes()), capture_bytes=request_copy.stat().st_size, frozen_revision=indexes['after']['revision'], logical_root=str(corpus), corpus_files=len(frozen['manifest']), corpus_hashes_preserved=True, index_signature_integrity=True, determinism=True, metrics={key: {arm: r[key] for arm, r in receipts.items()} for key in metrics}, optional_selection=selection, mandatory_scope=a['required_input_checks'], controls='Same slug, config, empty settled answers, tools, initial history, instructions and logical root. Full README, request, testing rules, commands, protection and approval authority retained. Active Refine contracts and settled answers covered separately by native acceptance.', limitations=['UTF-8 bytes are not tokens; no speed, monetary, cache or quality claim.', 'Determinism is repeated byte identity within each VM, not cross-VM map serialization ordering.', 'Static selection telemetry is retained separately; b2 clamps excerpt bytes to source size, so it differs from actual rendered optional-body bytes.', 'Initial rendering only, not total conversation growth. Provider-known usage is unavailable: no provider call was made.', 'Historical trial: first call 243677 provider input tokens / 888012 serialized input bytes; later token counts 248139/253150/255711 are per call, not cumulative. Static included/omitted selection recurred each call; not total prompt size or new savings.'], evidence=str(destination))
(destination / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({k: v for k, v in report.items() if k != 'optional_selection'}, indent=2))
