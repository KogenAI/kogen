#!/usr/bin/env python3
"""External fake-provider boundary for a disposable Shaping feasibility proof."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path.cwd()
RUN = Path(os.environ['ROLE_CONTEXT_PROBE_RUN'])
PHASE = os.environ['ROLE_CONTEXT_PROBE_PHASE']
LOG = RUN / PHASE
LOG.mkdir(exist_ok=True)
ARGS = sys.argv[1:]
PROMPT = sys.stdin.read()

def save(name, data):
    (LOG / name).write_text(json.dumps(data, indent=2) + '\n')

def count(name):
    p = LOG / name
    n = int(p.read_text()) + 1 if p.exists() else 1
    p.write_text(str(n))
    return n

def read_context():
    lines = PROMPT.splitlines()
    packets = [json.loads(lines[i + 1]) for i, line in enumerate(lines[:-1])
               if line in {'KOGEN_TRACKING_CONTEXT', 'KOGEN_TASK_CONTEXT'}]
    packet = packets[-1]
    if PHASE == 'accepted-engine':
        assert 'KOGEN_TRACKING_CONTEXT' in lines and 'KOGEN_TASK_CONTEXT' not in lines
        records = list((ROOT / '.kogen/runtime/scenario-tracking').glob('*/record.json'))
        assert len(records) == 1
        path = records[0]
    else:
        assert 'KOGEN_TASK_CONTEXT' in lines and 'KOGEN_TRACKING_CONTEXT' not in lines
        assert 'ROLE_CONTEXT_LARGE_SENTINEL' not in PROMPT
        assert not any(k in packet for k in ['scenarios', 'risks', 'history', 'handoff', 'developer_reference_snapshots'])
        path = ROOT / packet['tracking_path']
    record = json.loads(path.read_text())
    attempt = record['attempts'][-1]
    assert packet['attempt_token'] == attempt['attempt_token']
    if '--output-schema' in ARGS:
        assert packet['candidate_id'] == attempt['candidate_id']
    findings = [f for f in record['findings'] if f['status'] == 'open']
    return record, attempt, findings

def refs():
    return [{'path': 'probe-value.txt', 'locator': 'current value compared to linked requirement'},
            {'path': 'lib/kogen/build.ex', 'locator': 'locator-based task context prototype'},
            {'path': '.kogen/runtime/context-evidence.txt', 'locator': 'large retained evidence sentinel'}]

def hook():
    r = subprocess.run(['sh', '.codex/hooks/check.sh'], input=json.dumps({'session_id': 'probe-developer'}), text=True, capture_output=True)
    n = count('hook-count')
    save(f'hook-{n}.json', {'returncode': r.returncode, 'stdout': r.stdout, 'stderr': r.stderr})
    gate_log = ROOT / '.kogen/runtime/stop-check.log'
    if gate_log.exists():
        shutil.copy2(gate_log, LOG / f'gate-{n}.log')
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout).get('continue') is True, r.stdout

def main():
    role = 'reviewer' if '--output-schema' in ARGS else 'developer'
    n = count(role + '-count')
    save(f'{role}-{n}-argv.json', ARGS)
    (LOG / f'{role}-{n}-prompt.txt').write_text(PROMPT)
    record, attempt, findings = read_context()
    slug = os.environ['ROLE_CONTEXT_PROBE_SLUG']
    requirement_path = ROOT / '.kogen/intents/approved' / slug / 'requirement.json'
    requirement = json.loads(requirement_path.read_text())
    assert requirement['path'] == 'probe-value.txt'
    if role == 'developer':
        if n == 1:
            assert 'resume' not in ARGS
            if PHASE == 'accepted-engine':
                candidate = RUN / 'candidate'
                paths = json.loads((RUN / 'prototype-paths.json').read_text())
                for relative in paths:
                    target = ROOT / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(candidate / relative, target)
            (ROOT / requirement['path']).write_text('stale\n')
            (ROOT / '.kogen/runtime/context-evidence.txt').write_text('ROLE_CONTEXT_LARGE_SENTINEL' * 45000)
        else:
            assert 'resume' in ARGS and ARGS[-2] == 'probe-developer'
            if n == 3:
                (ROOT / requirement['path']).write_text(requirement['expected'] + '\n')
        hook()
        response = {'attempt_token': attempt['attempt_token'], 'scenarios': [] if n == 1 else [
            {'id': s['id'], 'status': 'ready', 'claim': 'candidate available for independent file comparison', 'implementation': refs(), 'evidence': refs()}
            for s in record['scenarios']], 'risks': [], 'findings': [
            {'id': f['id'], 'status': 'addressed', 'response': 'current file repaired against linked requirement', 'evidence': refs()}
            for f in findings]}
        sid = 'probe-developer'
        print(json.dumps({'type': 'thread.started', 'thread_id': sid}))
        print(json.dumps({'type': 'item.completed', 'item': {'type': 'agent_message', 'text': json.dumps(response)}}))
    else:
        current = (ROOT / requirement['path']).read_text().strip()
        source = (ROOT / 'lib/kogen/build.ex').read_text()
        good = current == requirement['expected'] and 'KOGEN_TASK_CONTEXT' in source and 'defp tracking_context' not in source
        save(f'reviewer-{n}-observation.json', {'actual': current, 'expected': requirement['expected'], 'source_sha256': hashlib.sha256(source.encode()).hexdigest(), 'verdict': 'accept' if good else 'rework', 'attempt_token': attempt['attempt_token']})
        response = {'candidate_id': attempt['candidate_id'], 'attempt_token': attempt['attempt_token'], 'verdict': 'accept' if good else 'rework',
            'scenarios': [{'id': s['id'], 'status': 'satisfied' if good else 'needs_rework', 'reason': f'current value {current!r}; linked requirement {requirement["expected"]!r}; locator implementation inspected', 'evidence': refs()} for s in record['scenarios']],
            'dispositions': [{'id': f['id'], 'status': 'closed' if good else 'open', 'reason': 'current source comparison', 'evidence': refs()} for f in findings],
            'findings': [] if good else [{'scenario_ids': [s['id'] for s in record['scenarios']], 'reason': 'current value fails linked requirement', 'evidence': refs()}]}
        Path(ARGS[ARGS.index('--output-last-message') + 1]).write_text(json.dumps(response))
        sid = f'probe-reviewer-{n}'
        print(json.dumps({'type': 'thread.started', 'thread_id': sid}))
    print(json.dumps({'type': 'turn.completed', 'thread_id': sid}))

if __name__ == '__main__':
    main()
