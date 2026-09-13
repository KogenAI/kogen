#!/usr/bin/env python3
"""Offline integrity controls for the maintained five-session shaping evaluation."""
import argparse, hashlib, json, re, shutil, tempfile
from pathlib import Path

CASES = ("csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation")
MAX_SECONDS = 600
MAX_SCRIPTED_REPLIES = 6

def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def reject(condition, message):
    if not condition: raise ValueError(message)

def relative_safe(root, value):
    reject(isinstance(value, str) and value, "evidence path is required")
    path = Path(value)
    reject(not path.is_absolute() and ".." not in path.parts and "." not in path.parts, "unsafe evidence path")
    resolved = (root / path).resolve()
    reject(resolved.is_relative_to(root.resolve()) and resolved.is_file() and not resolved.is_symlink(), "missing or escaped evidence")
    return resolved

def case_root(evaluation_root, case): return evaluation_root / 'runs' / case

def draft_identity(path):
    intent = path / 'intent.yaml'
    reject(intent.is_file(), 'draft intent.yaml missing')
    text = intent.read_text(errors='strict')
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # Flow-map YAML may start with "{" without being JSON. Use the same
        # supported parser boundary, never a partial identity regex.
        import importlib.util
        spec = importlib.util.spec_from_file_location("integrity_yaml_driver", Path(__file__).with_name("driver.py"))
        driver = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(driver)
            data = driver.parse_yaml_mapping(intent, case=path.parent.name)
        except (RuntimeError, KeyError) as exc:
            raise ValueError(f"Draft YAML unavailable or invalid: {exc}") from exc
    reject(isinstance(data, dict) and isinstance(data.get('id'), str) and data['id'], 'draft identity missing')
    reject(data.get('status') != 'approved', 'draft claims approval')
    return data['id']

def raw_rollouts(run):
    paths = sorted((run / 'owned-rollouts').glob('*.jsonl'))
    reject(paths, 'native rollout evidence missing')
    return paths

def rollout_events(path):
    events=[]
    for line in path.read_text(errors='replace').splitlines():
        try: events.append(json.loads(line))
        except json.JSONDecodeError: raise ValueError('malformed native rollout')
    reject(events, 'empty native rollout')
    return events

def ordered_turn_bindings(events, messages):
    """Bind the ordered ledger to distinct native user turns and completions.

    Repeated text on distinct turns is legitimate. A later completed turn can
    never certify an earlier answer, and an interrupted answer is not complete.
    """
    cursor, bindings = 0, []
    for message in messages:
        reject(isinstance(message, dict), 'scripted message must be an object')
        wanted = message.get('submitted_text', message.get('text'))
        reject(isinstance(wanted, str) and wanted, 'submitted scripted input missing')
        found = None
        for index in range(cursor, len(events)):
            event = events[index]; payload = event.get('payload', {})
            if event.get('type') == 'response_item' and payload.get('type') == 'message' and payload.get('role') == 'user':
                content = payload.get('content', [])
                text = ''.join(part.get('text', '') for part in content if isinstance(part, dict))
                if text == wanted:
                    found = index
                    break
        reject(found is not None, 'next submitted message absent in native order')
        payload = events[found]['payload']
        contexts = [event.get('payload', {}).get('turn_id') for event in events[:found]
                    if event.get('type') == 'turn_context']
        metadata = payload.get('internal_chat_message_metadata_passthrough') or {}
        turn = metadata.get('turn_id') or (contexts[-1] if contexts else None)
        reject(isinstance(turn, str) and turn.strip(), 'scripted answer lacks nonblank turn binding')
        reject(not contexts or contexts[-1] == turn, 'scripted answer conflicts with native turn context')
        reject(turn not in [item['turn_id'] for item in bindings], 'scripted answers reuse native turn')
        completed = None
        for index in range(found + 1, len(events)):
            event = events[index]; payload = event.get('payload', {}); kind = event.get('type')
            reject(not (kind == 'turn_context' and payload.get('turn_id') != turn), 'distinct native turn intervenes before completion')
            reject(not (kind == 'response_item' and payload.get('type') == 'message' and payload.get('role') == 'user'), 'native user intervenes before completion')
            if kind == 'event_msg':
                reject(payload.get('type') not in {'task_aborted','task_interrupted','turn_interrupted'}, 'native turn interrupted')
                if payload.get('type') == 'task_complete':
                    reject(payload.get('turn_id') == turn, 'other native completion intervenes')
                    completed = index
                    break
        reject(completed is not None, 'scripted answer lacks exact matching terminal event')
        bindings.append({'user_index': found, 'turn_id': turn, 'completion_index': completed})
        cursor = completed + 1
    return bindings

def public_transcript(run):
    sources, visible = [], []
    for path in raw_rollouts(run):
        hashed = digest(path)
        sources.append({'path': path.name, 'sha256': hashed})
        for index, event in enumerate(rollout_events(path)):
            payload = event.get('payload', {})
            if event.get('type') == 'response_item' and payload.get('type') in {'message','function_call','function_call_output','custom_tool_call','custom_tool_call_output'}:
                reject(payload.get('channel') != 'analysis' or payload.get('type') != 'message', 'private assistant analysis in public transcript')
                visible.append({'source':path.name,'source_sha256':hashed,'event_index':index,'event':event})
    return {'schema_version':1,'native_sources':sources,'visible_events':visible}

def validate_native(run, receipt, messages):
    reject(json.loads((run / 'public-transcript.json').read_text()) == public_transcript(run),
           'public transcript differs from exact native events')
    metadata = json.loads((run / 'owned-session-metadata.json').read_text())
    reject(isinstance(metadata, list) and metadata, 'native session metadata missing')
    streams = {path: rollout_events(path) for path in raw_rollouts(run)}
    events = [event for stream in streams.values() for event in stream]
    ids = {item.get('id') for item in metadata if item.get('id')}
    stream_ids = {next((event.get('payload', {}).get('id') for event in stream if event.get('type') == 'session_meta'), None): stream for stream in streams.values()}
    found_ids = set(stream_ids)
    reject(len(ids) == len(metadata) and ids == found_ids and None not in ids, 'native rollout does not support session metadata')
    roots = [item for item in metadata if not isinstance(item.get('source'), dict) or 'subagent' not in item['source']]
    reject(len(roots) == 1, 'exactly one native root is required')
    root = roots[0]
    expected_profiles = receipt.get('correlation', {}).get('requested_profiles', receipt.get('configured_profiles', {}))
    expected = expected_profiles.get('root') if isinstance(expected_profiles, dict) else None
    reject(isinstance(expected, list) and len(expected) >= 2, 'configured root profile missing')
    root_events = stream_ids.get(root.get('id'), [])
    root_turns = [event.get('payload', {}) for event in root_events if event.get('type') == 'turn_context']
    reject(root_turns and all((turn.get('model'), turn.get('effort') or turn.get('reasoning_effort')) == tuple(expected[:2]) for turn in root_turns), 'native root turn differs from configured profile')
    reject(tuple(root.get('models', [])) == (expected[0],) and tuple(root.get('efforts', [])) == (expected[1],), 'metadata conflicts with native root profile')
    bindings = ordered_turn_bindings(root_events, messages)
    turns = [item['turn_id'] for item in bindings]
    reject([item.get('turn_id') for item in receipt.get('terminal_events', [])] == turns,
           'receipt terminals differ from ordered native answers')
    reject(receipt.get('terminal_turn_bindings') == turns,
           'receipt turn bindings differ from native answers')
    for item in metadata:
        native = stream_ids[item['id']]
        native_meta = [event['payload'] for event in native if event.get('type') == 'session_meta']
        reject(len(native_meta) == 1 and native_meta[0].get('source') == item.get('source'), 'metadata source differs from native owner')
        source = item.get('source')
        if isinstance(source, dict) and 'subagent' in source:
            spawn = source['subagent'].get('thread_spawn', {})
            reject(spawn.get('parent_thread_id') in ids, 'helper parent is not an owned session')
            role = spawn.get('agent_role') or spawn.get('agent_type')
            profile = {'explorer':'scout', 'worker':'worker', 'default':'expert'}.get(role)
            expected_helper = expected_profiles.get(profile)
            reject(isinstance(expected_helper, list) and len(expected_helper) == 2, 'helper requested profile missing')
            turns = [event['payload'] for event in native if event.get('type') == 'turn_context']
            reject(turns and all([turn.get('model'), turn.get('effort') or turn.get('reasoning_effort')] == expected_helper for turn in turns), 'native helper profile differs')
        reject(any(event.get('type') == 'event_msg' and event.get('payload', {}).get('type') == 'task_complete' for event in native), 'owned native session has no completion')
    correlation = receipt.get('correlation', {})
    reject(correlation.get('exactly_one_root') is True, 'receipt root correlation missing')
    reject(correlation.get('all_owned_terminal') is True, 'receipt terminal correlation missing')
    reject(correlation.get('all_profiles_match') is True, 'receipt profile correlation missing')

def validate_receipt(receipt):
    reject(receipt.get('case') in CASES, 'unknown case')
    reject(0 <= receipt.get('elapsed_seconds', -1) <= MAX_SECONDS, 'session time bound')
    reject(0 <= receipt.get('scripted_replies', -1) <= MAX_SCRIPTED_REPLIES, 'scripted reply bound')
    reject(receipt.get('outcome') == 'completed', 'session did not complete')
    reject(receipt.get('git_status', {}).get('baseline_unchanged') is True, 'fixture baseline changed')
    reject(receipt.get('git_status', {}).get('draft_exists') is True, 'saved draft missing')
    identity = receipt.get('source_identity', {})
    reject(identity.get('unchanged') is True and identity.get('baseline') and identity.get('baseline') == identity.get('after'), 'fixture source identity changed')

def validate_csv_probe(evidence, probe):
    names = ('plain.csv', 'bom.csv', 'invalid-date.csv', 'naive_reader.py', 'reader_control.py')
    hashes = probe.get('input_sha256')
    reject(isinstance(hashes, dict) and set(hashes) == set(names), 'CSV probe input bindings incomplete')
    for name in names:
        path = evidence / name
        reject(path.is_file() and hashes[name] == digest(path), 'CSV probe input hash mismatch')
    plain, bom = probe.get('plain_result', {}), probe.get('bom_result', {})
    comparison, invalid = probe.get('plain_vs_bom', {}), probe.get('invalid_date_control', {})
    reject(isinstance(probe.get('command'), list) and probe['command'], 'CSV probe command missing')
    reject(plain.get('exit') == 0 and bom.get('exit') == 0 and
           isinstance(plain.get('stdout'), str) and plain['stdout'] and
           isinstance(bom.get('stdout'), str) and bom['stdout'] and
           comparison == {'plain_exit': plain['exit'], 'bom_exit': bom['exit'],
                          'same_output': plain['stdout'] == bom['stdout']} and
           comparison['same_output'] is False, 'CSV plain/BOM control contradicts observed results')
    reject(isinstance(invalid.get('command'), list) and invalid['command'] and
           isinstance(invalid.get('exit'), int) and invalid['exit'] != 0 and
           isinstance(invalid.get('stderr'), str) and invalid['stderr'],
           'CSV invalid-date control missing or successful')

def validate_booking_setup(old_receipt, inventory, observation):
    reject(observation.get('old_receipt_path') == 'evidence/old-receipt.md' and observation.get('missing_connection') == '.tmp/calendar-run-17/connection.json' and observation.get('inventory'), 'booking setup observation missing')
    reject(observation.get('old_receipt_sha256') == digest(old_receipt) and
           observation.get('inventory_sha256') == digest(inventory) and
           observation.get('old_receipt') == old_receipt.read_text() and
           observation.get('inventory') == inventory.read_text(), 'booking setup input bindings differ')
    inventory_text = inventory.read_text(errors='replace').lower()
    reject('.tmp/calendar-run-17/connection.json' in old_receipt.read_text(errors='replace') and
           ('absent' in inventory_text or 'no .tmp directory' in inventory_text),
           'stale booking setup gap not retained')

def validate_case(evaluation_root, case):
    run = case_root(evaluation_root, case)
    receipt_path, messages_path = run / 'receipt.json', run / 'messages.json'
    delivery_path = run / 'input-delivery.json'
    reject(receipt_path.is_file() and messages_path.is_file() and delivery_path.is_file(), f'missing case receipt: {case}')
    receipt, messages = json.loads(receipt_path.read_text()), json.loads(messages_path.read_text())
    delivery = json.loads(delivery_path.read_text())
    validate_receipt(receipt)
    reject(receipt['case'] == case, 'case receipt mismatch')
    reject(isinstance(messages, list) and len(messages) == receipt['scripted_replies'], 'scripted message count mismatch')
    readme = run / 'fixture-source' / 'README.md'
    reject(delivery.get('case') == case and delivery.get('available_before_dispatch') is True and
           delivery.get('request_path') == 'README.md' and readme.is_file() and
           delivery.get('readme_sha256') == digest(readme) and
           delivery.get('request') in readme.read_text(), 'initial request was not frozen before dispatch')
    validate_native(run, receipt, messages)
    bindings = receipt.get('terminal_turn_bindings')
    if bindings is not None:
        reject(isinstance(bindings, list) and all(isinstance(value, str) and value.strip() for value in bindings), 'terminal turn bindings missing')
        reject(len(bindings) == len(set(bindings)), 'terminal turn bindings are not distinct')
    if case == 'csv-continuation':
        reject(receipt.get('scripted_replies') == 2 and len(messages) == 2 and len(bindings) == 2, 'CSV continuation requires two ordered answers and two terminal bindings')
        intermediate = run / 'drafts-by-turn' / '0' / 'questions.md'
        reject(intermediate.is_file() and receipt.get('intermediate_draft_sha256') == digest(intermediate), 'CSV continuation intermediate Draft snapshot missing')
        partial = intermediate.read_text(errors='replace').lower()
        reject('output' in partial and any(term in partial for term in ('replace', 'replacement', 'overwrite')) and '?' in partial, 'CSV continuation partial assent did not preserve the remaining output replacement question')
    draft = run / 'draft'
    identity = draft_identity(draft)
    reject(all((draft / name).is_file() for name in ('scenarios.yaml', 'questions.md')), 'saved Draft contract files missing')
    reject(not (draft / 'approval.md').exists(), 'evaluation Draft was approved')
    state = json.loads((run / 'draft-state.json').read_text())
    baseline_state = state.get('baseline')
    reject(state.get('intent_id') == identity and isinstance(baseline_state, dict) and baseline_state.get('branch') and baseline_state.get('head') and state.get('visit_id') and state.get('unapproved') is True, 'draft provenance state missing')
    baseline = json.loads((run / 'source-baseline.json').read_text())
    after = json.loads((run / 'source-after.json').read_text())
    reject(isinstance(baseline, dict) and baseline and baseline == after == receipt['source_identity']['baseline'], 'frozen source baseline differs')
    fixture = evaluation_root / case
    evidence = run / 'evidence' if (run / 'evidence').is_dir() else fixture / 'evidence'
    reject(evidence.is_dir(), 'fixture source facts missing')
    if case.startswith('csv'):
        reject((evidence / 'plain.csv').is_file() and (evidence / 'bom.csv').is_file(), 'CSV probe inputs missing')
        if case == 'csv-flawed':
            probe = json.loads((run / 'csv-probe-result.json').read_text())
            validate_csv_probe(evidence, probe)
    if case.startswith('booking'):
        old_receipt, inventory = evidence / 'old-receipt.md', evidence / 'inventory.txt'
        reject(old_receipt.is_file() and inventory.is_file(), 'booking reachability inputs missing')
        if case == 'booking-flawed':
            observation = json.loads((run / 'booking-setup-observation.json').read_text())
            validate_booking_setup(old_receipt, inventory, observation)
    return identity

def validate_public_receipt(run, receipt):
    public=json.loads((run / 'review-receipt.json').read_text())
    for key in ('case','slug','started','ended','elapsed_seconds','configured_profiles','transport_exit',
                'initial_messages','scripted_replies','outcome','failure','terminal_turn_bindings',
                'intermediate_draft_sha256'):
        reject(public.get(key) == receipt.get(key), f'public review receipt differs: {key}')
    reject(public.get('git_status') == {key: receipt['git_status'][key] for key in ('baseline_unchanged','draft_exists')},
           'public review Git status differs')
    source=public.get('source_identity', {})
    reject(source.get('unchanged') == receipt['source_identity']['unchanged'] and
           source.get('baseline_sha256') == digest(run / 'source-baseline.json') and
           source.get('after_sha256') == digest(run / 'source-after.json'), 'public source identity differs')
    reject(public.get('terminal_events') == [{key:event.get(key) for key in ('at','turn_id','draft_sha256')}
                                             for event in receipt.get('terminal_events', [])],
           'public terminal evidence differs')
    correlation=public.get('correlation', {})
    reject(all(correlation.get(key) == receipt.get('correlation', {}).get(key) for key in
               ('exactly_one_root','all_owned_terminal','all_profiles_match','roots','owned','requested_profiles')),
           'public native correlation differs')
    cleanup=public.get('cleanup', {})
    reject(cleanup.get('attempts') == len(receipt.get('cleanup', [])) and
           cleanup.get('all_reaped') == all(item.get('all_reaped') is True for item in receipt.get('cleanup', [])),
           'public cleanup summary differs')


def validate_manifest(root, manifest_path):
    payload=json.loads(manifest_path.read_text())
    reject(set(payload) == {'schema_version','required_evidence'} and payload['schema_version'] == 1, 'manifest schema')
    entries=payload['required_evidence']; reject(isinstance(entries,list) and entries, 'required evidence is empty')
    seen=set()
    for entry in entries:
        reject(set(entry)=={'path','sha256'}, 'invalid manifest entry')
        path=relative_safe(root, entry['path'])
        reject(entry['path'] not in seen, 'duplicate evidence path'); seen.add(entry['path'])
        reject(isinstance(entry['sha256'],str) and re.fullmatch(r'[0-9a-f]{64}',entry['sha256']) is not None, 'invalid evidence hash')
        reject(digest(path)==entry['sha256'], 'evidence hash mismatch')
        parts=Path(entry['path']).parts
        reject('owned-rollouts' not in parts and 'private-raw-rollouts' not in parts,
               'manifest includes private rollout stream')
        reject(Path(entry['path']).name not in {'receipt.json','transport.log','pty.log'} and
               not Path(entry['path']).name.startswith('resume-') and not Path(entry['path']).name.endswith('-pty.log'),
               'manifest includes private runtime log or detailed receipt')
    evaluation_root = manifest_path.parent
    relative_root = evaluation_root.relative_to(root).as_posix()
    for case in CASES:
        required = [
            f'{relative_root}/runs/{case}/review-receipt.json',
            f'{relative_root}/runs/{case}/messages.json',
            f'{relative_root}/runs/{case}/public-transcript.json',
            f'{relative_root}/runs/{case}/owned-session-metadata.json',
            f'{relative_root}/runs/{case}/draft/intent.yaml',
            f'{relative_root}/runs/{case}/draft/scenarios.yaml',
            f'{relative_root}/runs/{case}/draft/questions.md',
            f'{relative_root}/runs/{case}/draft-state.json',
        ]
        run = case_root(evaluation_root, case)
        required.extend(str(path.relative_to(root)) for path in (run / 'draft').rglob('*') if path.is_file())
        required.extend(str(path.relative_to(root)) for path in (run / 'fixture-source').rglob('*') if path.is_file())
        evidence_names=('plain.csv','bom.csv','invalid-date.csv','naive_reader.py','reader-receipt.md',
                        'csv-format.json','source-lifecycle.json','inventory.txt','old-receipt.md','facts.json','protocol.json','prerequisite-results.json','reader_control.py','calendar_adapter.py','capability-seed.json',
                        'synthetic-calendar.json','synthetic-policy.json','maintained-capability.json',
                        'complete-input-receipt.json','complete-control-receipt.json','ui-prerequisite-receipt.json',
                        'fixture-integration-contract.md','current-prerequisite-receipt.json','prerequisite_control.py','fixture-contract.md')
        required.extend(str((run / 'evidence' / name).relative_to(root)) for name in evidence_names
                        if (run / 'evidence' / name).is_file())
        if case == 'csv-continuation':
            partial = run / 'drafts-by-turn' / '0'
            required.extend(f'{relative_root}/runs/{case}/drafts-by-turn/0/{name}' for name in ('intent.yaml', 'scenarios.yaml', 'questions.md'))
            required.extend(str(path.relative_to(root)) for path in partial.rglob('*') if path.is_file())
        if case == 'csv-flawed': required.append(f'{relative_root}/runs/{case}/csv-probe-result.json')
        if case == 'booking-flawed': required.append(f'{relative_root}/runs/{case}/booking-setup-observation.json')
        reject(all(path in seen for path in required), f'manifest omits required {case} evidence')
        validate_public_receipt(run, json.loads((run / 'receipt.json').read_text()))
    ids={case:validate_case(evaluation_root,case) for case in CASES}
    metadata = evaluation_root / 'continuation-seed-metadata.json'
    reject(metadata.is_file() and str(metadata.relative_to(root)) in seen, 'continuation seed metadata missing from manifest')
    seed = evaluation_root / 'continuation-seed'
    frozen = seed / 'frozen-hashes.json'
    reject(frozen.is_file() and str(frozen.relative_to(root)) in seen, 'continuation seed inventory missing from manifest')
    seed_hashes = json.loads(frozen.read_text())
    reject(isinstance(seed_hashes, dict) and seed_hashes, 'continuation seed hash inventory empty')
    reject(set(seed_hashes) == {str(path.relative_to(seed)) for path in seed.rglob('*') if path.is_file() and path != frozen}, 'continuation seed inventory coverage differs')
    for relative, expected in seed_hashes.items():
        path = relative_safe(seed, relative)
        reject(digest(path) == expected and str(path.relative_to(root.resolve())) in seen, 'continuation seed bytes or manifest coverage changed')
    reject(ids['csv-continuation'] == draft_identity(seed), 'continuation lost frozen seed identity')
    counterexamples=evaluation_root/'semantic-counterexamples.json'
    reject(counterexamples.is_file() and str(counterexamples.relative_to(root)) in seen, 'semantic counterexamples missing from manifest')
    counters=json.loads(counterexamples.read_text())
    reject(isinstance(counters,list) and len(counters) >= 6 and all(isinstance(x,dict) and x.get('wrong_result') for x in counters), 'semantic counterexamples incomplete')
    return payload

def write(path, content): path.parent.mkdir(parents=True, exist_ok=True); path.write_text(content)
def fake_rollout(session, message, include_startup=False):
    messages = message if isinstance(message, list) else [message]
    events = [{'type':'session_meta','payload':{'id':session,'cwd':'fixture','source':'cli'}}]
    if include_startup:
        events.extend([
            {'type':'turn_context','payload':{'model':'gpt-6-astra','effort':'low','turn_id':'startup'}},
            {'type':'event_msg','payload':{'type':'task_complete','turn_id':'startup'}},
        ])
    for index, text in enumerate(messages, 1):
        turn = f't{index}'
        events.extend([
            {'type':'turn_context','payload':{'model':'gpt-6-astra','effort':'low','turn_id':turn}},
            {'type':'response_item','payload':{'type':'message','role':'user','content':[{'text':text}], 'internal_chat_message_metadata_passthrough': {'turn_id': turn}}},
            {'type':'event_msg','payload':{'type':'task_complete','turn_id':turn}},
        ])
    return '\n'.join(json.dumps(x) for x in events)+'\n'

def make_positive(root):
    base=root/'.kogen/runtime/shaping-evaluation'
    for case in CASES:
        run=base/'runs'/case; fixture=base/case
        messages = (['partial invalid-row answer', 'final transaction policy'] if case == 'csv-continuation'
                    else [f'clarification for {case}'] if case in ('csv-flawed', 'booking-flawed') else [])
        write(run/'messages.json',json.dumps([{'text':item, 'submitted_text':item} for item in messages]))
        write(run/'owned-session-metadata.json',json.dumps([{'id':case,'source':'cli','models':['gpt-6-astra'],'efforts':['low'],'task_complete_count':1}]))
        write(run/'owned-rollouts'/f'{case}.jsonl',fake_rollout(case,messages,include_startup=True))
        write(run/'public-transcript.json', json.dumps(public_transcript(run)))
        intent_id = 'csv-original' if case in ('csv-flawed','csv-continuation') else case
        write(run/'draft'/'intent.yaml', json.dumps({'id': intent_id, 'status': 'draft'}))
        write(run/'draft/scenarios.yaml', '- id: synthetic-control\n')
        write(run/'draft/questions.md', 'Synthetic integrity fixture, not semantic proof.\n')
        write(run/'initial-draft/intent.yaml', (run/'draft/intent.yaml').read_text())
        write(run/'initial-draft/scenarios.yaml', (run/'draft/scenarios.yaml').read_text())
        write(run/'initial-draft/questions.md', 'Initial reviewable state.\n')
        source={'README.md':'a'*64}
        write(run/'draft-state.json', json.dumps({'intent_id': intent_id, 'baseline':{'branch':'main','head':'abc123'}, 'visit_id': 'visit-2' if case == 'csv-continuation' else 'visit-1', 'unapproved':True}))
        if case == 'csv-continuation':
            write(run/'drafts-by-turn/0/intent.yaml', (run/'draft/intent.yaml').read_text())
            write(run/'drafts-by-turn/0/scenarios.yaml', (run/'draft/scenarios.yaml').read_text())
            write(run/'drafts-by-turn/0/questions.md', 'What should happen to an existing output on replacement?\n')
        write(run/'source-baseline.json', json.dumps(source)); write(run/'source-after.json', json.dumps(source))
        write(fixture/'evidence/plain.csv','date,value\n2026-09-01,1\n')
        write(fixture/'evidence/bom.csv','\ufeffdate,value\n2026-09-01,1\n')
        write(fixture/'evidence/old-receipt.md','.tmp/calendar-run-17/connection.json absent\n')
        write(fixture/'evidence/inventory.txt','maintained setup is absent\n')
        write(fixture/'evidence/invalid-date.csv','date,value\n2026-09-31,1\n')
        write(fixture/'evidence/naive_reader.py','retained synthetic reader input\n')
        write(fixture/'evidence/reader_control.py','retained synthetic compatible reader\n')
        request=f'current request for {case}; save without approval'
        write(run/'fixture-source/README.md', request+'\n')
        write(run/'input-delivery.json', json.dumps({'case':case,'request':request,'request_path':'README.md',
              'readme_sha256':digest(run/'fixture-source/README.md'),'available_before_dispatch':True,'recorded_at':0}))
        if case == 'csv-flawed':
            write(run/'csv-probe-result.json', json.dumps({
                'command':['python3','-B','probe.py'],
                'input_sha256':{name:digest(fixture/'evidence'/name) for name in ('plain.csv','bom.csv','invalid-date.csv','naive_reader.py','reader_control.py')},
                'plain_result':{'exit':0,'stdout':'plain'}, 'bom_result':{'exit':0,'stdout':'BOM'},
                'plain_vs_bom':{'plain_exit':0,'bom_exit':0,'same_output':False},
                'invalid_date_control':{'command':['python3','-B','invalid.py'],'exit':1,'stderr':'invalid date'}}))
        if case == 'booking-flawed':
            old, inventory = fixture/'evidence/old-receipt.md', fixture/'evidence/inventory.txt'
            write(run/'booking-setup-observation.json', json.dumps({
                'old_receipt_path':'evidence/old-receipt.md','missing_connection':'.tmp/calendar-run-17/connection.json',
                'old_receipt_sha256':digest(old),'old_receipt':old.read_text(),
                'inventory_path':'evidence/inventory.txt','inventory_sha256':digest(inventory),'inventory':inventory.read_text()}))
        receipt={'case':case,'slug':case,'started':1,'ended':2,'elapsed_seconds':1,'configured_profiles':{},'transport_exit':0,'initial_messages':1,'scripted_replies':len(messages),'initial_terminal_event':{'turn_id':'startup'},'outcome':'completed','failure':None,'cleanup':[],'terminal_events':[{'turn_id':f't{i+1}'} for i in range(len(messages))],'git_status':{'baseline_unchanged':True,'draft_exists':True},'source_identity':{'baseline':source,'after':source,'unchanged':True},'terminal_turn_bindings': [f't{i+1}' for i in range(len(messages))], 'intermediate_draft_sha256': digest(run/'drafts-by-turn/0/questions.md') if case == 'csv-continuation' else None, 'correlation':{'exactly_one_root':True,'all_owned_terminal':True,'all_profiles_match':True,'roots':['root'],'owned':[],'requested_profiles':{'root':['gpt-6-astra','low']}}}
        write(run/'receipt.json',json.dumps(receipt))
        public={key:receipt.get(key) for key in ('case','slug','started','ended','elapsed_seconds','configured_profiles','transport_exit','initial_messages','scripted_replies','initial_terminal_event','outcome','failure','terminal_turn_bindings','intermediate_draft_sha256')}
        public.update({'terminal_events':[{key:event.get(key) for key in ('at','turn_id','draft_sha256')} for event in receipt['terminal_events']],'correlation':{key:receipt['correlation'].get(key) for key in ('exactly_one_root','all_owned_terminal','all_profiles_match','roots','owned','requested_profiles')},'cleanup':{'all_reaped':True,'attempts':0},'git_status':receipt['git_status'],'source_identity':{'unchanged':True,'baseline_sha256':digest(run/'source-baseline.json'),'after_sha256':digest(run/'source-after.json')}})
        write(run/'review-receipt.json',json.dumps(public))
    write(base/'continuation-seed-metadata.json', json.dumps({'kind':'synthetic integrity control'}))
    seed = base / 'continuation-seed'
    write(seed/'intent.yaml', json.dumps({'id':'csv-original','status':'draft'}))
    write(seed/'questions.md', 'What output replacement policy?\n')
    write(seed/'frozen-hashes.json', json.dumps({str(path.relative_to(seed)):digest(path) for path in seed.rglob('*') if path.is_file()}))
    write(base/'semantic-counterexamples.json',json.dumps([{'wrong_result':str(i)} for i in range(6)]))

def manifest_for(root):
    candidates = [path for path in (root / '.kogen/runtime').iterdir() if (path / 'runs').is_dir()]
    reject(len(candidates) == 1, 'self-test evaluation root ambiguous')
    evaluation_root = candidates[0]
    entries=[]
    for path in sorted(evaluation_root.rglob('*')):
        if path.is_file() and not ({'owned-rollouts','private-raw-rollouts'} & set(path.parts)) and path.name not in {'receipt.json','transport.log','pty.log'} and not path.name.endswith('-pty.log'):
            entries.append({'path':str(path.relative_to(root)),'sha256':digest(path)})
    path=evaluation_root/'evidence-manifest.json'; write(path,json.dumps({'schema_version':1,'required_evidence':entries})); return path

def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        root=Path(tmp); make_positive(root)
        (root/'.kogen/runtime/shaping-evaluation').rename(root/'.kogen/runtime/shaping-evaluation-unique-123')
        manifest=manifest_for(root); validate_manifest(root,manifest)
        mutations=[
            ('forged public transcript', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/public-transcript.json', '{}'),
            ('fabricated native receipt', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/owned-rollouts/csv-flawed.jsonl', '{}\n'),
            ('false delegated helper claim', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/owned-session-metadata.json', None),
            ('altered submitted transport text', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/messages.json', 'submitted'),
            ('forged metadata profile', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/owned-session-metadata.json', 'profile'),
            ('forged public review receipt', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/review-receipt.json', 'public'),
            ('tracked source mutation', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-complete/receipt.json', None),
            ('incomplete case', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/booking-complete/receipt.json', 'incomplete'),
            ('invalid continuation identity', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-continuation/draft/intent.yaml', json.dumps({'id': 'replaced', 'status': 'draft'})),
            ('stale booking facts', root/'.kogen/runtime/shaping-evaluation-unique-123/booking-flawed/evidence/inventory.txt', ''),
            ('missing saved contract', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-complete/draft/scenarios.yaml', None),
            ('missing complete receipt', root/'.kogen/runtime/shaping-evaluation-unique-123/runs/booking-complete/receipt.json', None),
        ]
        for label,path,replacement in mutations:
            backup=path.read_bytes() if path.exists() else None
            if label=='tracked source mutation':
                data=json.loads(path.read_text()); data['source_identity']['after']={'README.md':'b'*64}; write(path,json.dumps(data))
            elif label=='false delegated helper claim':
                data=json.loads(path.read_text()); data.append({'id':'unobserved-helper','source':{'subagent':{}},'models':['gpt-5.6-luna'],'efforts':['low'],'task_complete_count':1}); write(path,json.dumps(data))
            elif label=='altered submitted transport text':
                data=json.loads(path.read_text()); data[0]['submitted_text']='unobserved submitted prompt'; write(path,json.dumps(data))
            elif label=='forged metadata profile':
                data=json.loads(path.read_text()); data[0]['models']=['wrong-model']; write(path,json.dumps(data))
            elif label=='forged public review receipt':
                data=json.loads(path.read_text()); data['outcome']='forged'; write(path,json.dumps(data))
            elif label=='incomplete case':
                data=json.loads(path.read_text()); data['outcome']='incomplete'; write(path,json.dumps(data))
            elif replacement is None: path.unlink()
            else: write(path,replacement)
            manifest=manifest_for(root)
            try: validate_manifest(root,manifest)
            except ValueError: pass
            else: raise AssertionError(f'{label} was accepted')
            if backup is None: path.unlink(missing_ok=True)
            else: path.parent.mkdir(parents=True,exist_ok=True); path.write_bytes(backup)
        manifest=manifest_for(root)
        payload=json.loads(manifest.read_text())
        private_path=root/'.kogen/runtime/shaping-evaluation-unique-123/runs/csv-flawed/owned-rollouts/csv-flawed.jsonl'
        payload['required_evidence'].append({'path':str(private_path.relative_to(root)),'sha256':digest(private_path)})
        write(manifest,json.dumps(payload))
        try: validate_manifest(root,manifest)
        except ValueError: pass
        else: raise AssertionError('manifested private rollout stream was accepted')
    print('shaping evaluation integrity controls: ok')

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--self-test',action='store_true'); parser.add_argument('--validate-manifest'); parser.add_argument('--root'); options=parser.parse_args()
    if options.self_test: self_test()
    elif options.validate_manifest:
        if not options.root: parser.error('--validate-manifest requires --root')
        validate_manifest(Path(options.root),Path(options.validate_manifest)); print('shaping evaluation manifest: valid')
