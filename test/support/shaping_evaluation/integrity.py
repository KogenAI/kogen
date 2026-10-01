#!/usr/bin/env python3
"""Offline integrity controls for the maintained five-session shaping evaluation."""
import argparse, hashlib, json, os, re, shutil, tempfile
from pathlib import Path

CASES = ("csv-flawed", "csv-complete", "booking-flawed", "booking-complete", "csv-continuation",
         "stateful-flawed", "stateful-complete")
MAX_SECONDS = 600
MAX_SCRIPTED_REPLIES = 6
SMOKE_MAX_SECONDS = 20 * 60
SMOKE_MIN_MESSAGES = 2

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

_YAML_DRIVER = None


def yaml_driver():
    """The driver's parser boundary, loaded once so its parse memo is reused
    across every Draft this module validates."""
    global _YAML_DRIVER
    if _YAML_DRIVER is None:
        import importlib.util
        spec = importlib.util.spec_from_file_location("integrity_yaml_driver", Path(__file__).with_name("driver.py"))
        driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(driver)
        _YAML_DRIVER = driver
    return _YAML_DRIVER


def draft_identity(path):
    intent = path / 'intent.yaml'
    reject(intent.is_file(), 'draft intent.yaml missing')
    text = intent.read_text(errors='strict')
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        # Flow-map YAML may start with "{" without being JSON. Use the same
        # supported parser boundary, never a partial identity regex.
        try:
            data = yaml_driver().parse_yaml_mapping(intent, case=path.parent.name)
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

SMOKE_CHECKS = ("start-returns-running", "running-then-settled", "first-question-seen", "all-explicit-messages-sent",
                "two-messages-sent", "follow-up-message-sent-after-turn",
                "first-answer-sent-mid-turn", "second-message-sent-after-turn", "final-state-ready",
                "answers-recorded-verbatim-with-input-tokens", "resumed-provider-ids-match", "status-presented-id",
                "earlier-revision-report-has-findings", "later-full-report-ready-for-final-revision",
                "no-answer-not-applied", "route-bound", "run-completed",
                "first-answer-original-turn-identified", "first-answer-steered-into-original-turn",
                "first-answer-recorded-in-original-turn", "audit-feedback-delivered-before-repair")
PRESENTATION_ID = re.compile(r'^p-[0-9]+-[0-9a-f]{12}$')

def validate_smoke_receipt(receipt):
    """Smoke is deliberately not a CASES member: one headless-flow engine session,
    graded nothing, bounded at SMOKE_MAX_SECONDS (the route's ready bound)."""
    reject(receipt.get('case') == 'smoke', 'unknown smoke case')
    reject(0 <= receipt.get('elapsed_seconds', -1) <= SMOKE_MAX_SECONDS, 'smoke route did not reach ready within its bound')
    replies = receipt.get('scripted_replies')
    reject(isinstance(replies, int) and SMOKE_MIN_MESSAGES <= replies <= MAX_SCRIPTED_REPLIES,
           'smoke scripted message bound')
    reject(receipt.get('outcome') == 'completed' and receipt.get('failure') is None, 'smoke session did not complete')
    reject(receipt.get('cleanup', {}).get('all_reaped') is True, 'smoke processes were not reaped')
    reject(receipt.get('git_status', {}).get('baseline_unchanged') is True, 'smoke fixture baseline changed')
    reject(receipt.get('git_status', {}).get('draft_exists') is True, 'smoke saved draft missing')
    reject(receipt.get('source_identity', {}).get('unchanged') is True, 'smoke fixture source identity changed')

def smoke_events(run):
    events = []
    for line in (run / 'engine-runtime' / 'events.jsonl').read_text().splitlines():
        try: event = json.loads(line)
        except json.JSONDecodeError: continue
        if isinstance(event, dict): events.append(event)
    return events

def _seconds(value):
    import datetime
    try: return datetime.datetime.fromisoformat(str(value).replace('Z', '+00:00')).timestamp()
    except ValueError: return None

def _norm(text): return re.sub(r'\s+', ' ', re.sub(r'(?m)^\s*>\s?', '', text)).strip()

def validate_first_answer_delivery(run, first, events, final_text):
    """Re-derives, from the engine's own events and input journal, that the first
    (mid-turn) answer was steered by the root hook into the launch that was running
    when it was sent, and was recorded by that turn: nothing needed a later launch
    to offer it (the runner re-sends every unrecorded input at turn end)."""
    original = (first or {}).get('running_turn') or {}
    launch = original.get('launch_id')
    started = next((e for e in events if e.get('event') == 'turn_started' and launch and e.get('launch_id') == launch), None)
    ended = next((e for e in events if e.get('event') == 'turn_ended' and started and e.get('turn') == started.get('turn')), None)
    requested, ended_at, started_at = (first or {}).get('requested_at'), _seconds((ended or {}).get('at')), _seconds((started or {}).get('at'))
    reject(started and ended and isinstance(requested, (int, float)) and ended_at is not None and started_at is not None and
           ended_at >= requested, 'smoke first answer was not sent while an identified turn ran')
    text = _norm((first or {}).get('text') or '')
    inputs = run / 'engine-runtime' / 'inputs'
    match = None
    for meta_path in sorted(inputs.glob('[0-9][0-9][0-9][0-9].json')):
        meta = json.loads(meta_path.read_text())
        body = meta_path.with_suffix('.md')
        if meta.get('kind') == 'message' and body.is_file() and text and _norm(body.read_text()) == text:
            match = (meta.get('id'), meta_path.stem); break
    reject(match is not None, 'smoke first answer input is not in the retained input journal')
    input_id, number = match
    offers = []
    offer_path = inputs / f'{number}.offers.jsonl'
    if offer_path.is_file():
        for line in offer_path.read_text().splitlines():
            try: offers.append(json.loads(line))
            except json.JSONDecodeError: continue
    steer = [o for o in offers if o.get('via') == 'steer' and o.get('launch_id') == launch and o.get('id') == input_id and
             _seconds(o.get('at')) is not None and started_at <= _seconds(o.get('at')) <= ended_at]
    reject(steer, 'smoke first answer was never steered into the turn that was running when it was sent')
    reject(all(o.get('launch_id') == launch and o.get('via') == 'steer' for o in offers),
           'smoke first answer needed a later launch to offer it')
    reject(f'[input {input_id}]' in final_text, 'smoke first answer was not recorded in the Draft')

def _jsonl_records(path):
    records = []
    if Path(path).is_file():
        for line in Path(path).read_text(errors='replace').splitlines():
            try: item = json.loads(line)
            except json.JSONDecodeError: continue
            if isinstance(item, dict): records.append(item)
    return records

def _open_blocking(finding):
    disputed = finding.get('disputable') is True and isinstance(finding.get('disposition'), dict) and \
        finding['disposition'].get('kind') == 'not-a-defect'
    return finding.get('severity') == 'blocking' and (finding.get('still_open') is True or not disputed)

def _launch_windows(events):
    """{launch_id: (start, end)} for every root launch: turn_started .. its turn_ended."""
    windows = {}
    for event in events:
        if event.get('event') != 'turn_started' or not event.get('launch_id'): continue
        ended = next((e for e in events if e.get('event') == 'turn_ended' and e.get('turn') == event.get('turn')), None)
        start, end = _seconds(event.get('at')), _seconds((ended or {}).get('at'))
        if start is not None and end is not None: windows[event['launch_id']] = (start, end)
    return windows

def audit_feedback_delivery(run, revision, events):
    """(ok, detail): actual host-facing feedback bytes reached a root launch.

    Offer and Stop journals describe producer-side attempts. Only receipts made
    by feedback_output.py after its stdout write and flush count as delivery.
    Provider identity comes from the captured harness metadata; the configured
    route is a separate name and must match the receipt independently.
    """
    run = Path(run)
    windows = _launch_windows(events)
    targets = {}
    for path in sorted((run / 'shaping-audits').glob('*/report.json')) + sorted((run / 'shaping-audits').glob('*/checkpoint.json')):
        try: report = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError): continue
        if isinstance(report, dict) and report.get('revision') and report.get('revision') != revision:
            blocking = [f for f in report.get('findings') or [] if isinstance(f, dict) and _open_blocking(f)]
            if blocking: targets[report['revision']] = [f.get('id') for f in blocking]
    if not revision or not targets:
        return False, f'no earlier revision had an open blocking finding to deliver (final {revision!r})'
    hooks = _jsonl_records(run / 'shaping-audits' / 'hook.jsonl')
    repaired = [_seconds(r.get('at')) for r in hooks if r.get('revision') == revision]
    repaired += [_seconds(e.get('at')) for e in events if e.get('event') == 'audit_started' and e.get('revision') == revision]
    repaired = [t for t in repaired if t is not None]
    if not repaired:
        return False, f'no retained evidence times the repaired revision {revision!r}'
    first_repaired = min(repaired)
    config_path = run / 'config-record.json'
    try:
        config = json.loads(config_path.read_text())
    except (OSError, json.JSONDecodeError):
        config = {}
    root = config.get('shaping_root')
    intent_id = config.get('shaping_intent_id')
    route = config.get('route')
    harness = config.get('harness')
    if not isinstance(root, str) or not isinstance(intent_id, str) or \
            not isinstance(route, str) or not route.strip() or harness not in ('codex', 'claude'):
        return False, 'missing expected root, intent id, configured route or captured harness in config-record.json'
    expected_root = os.path.realpath(root)
    expected_session = os.path.realpath(os.path.join(expected_root, '.kogen', 'runtime', 'shaping', intent_id))
    receipts = _jsonl_records(run / 'feedback-delivery' / 'receipts.jsonl')
    found, seen = [], []
    import base64
    import hashlib

    for target, ids in targets.items():
        notice_name = f'au-{target[:12]}'
        notice = run / 'engine-runtime' / 'notices' / f'{notice_name}.json'
        try:
            notice_meta = json.loads(notice.read_text())
        except (OSError, json.JSONDecodeError):
            notice_meta = None
        offers = _jsonl_records(run / 'engine-runtime' / 'notices' / f'{notice_name}.offers.jsonl')
        stop_blocks = [item for item in hooks if item.get('revision') == target and
                       item.get('decision') == 'block' and item.get('blocking')]
        for receipt in receipts:
            launch = receipt.get('launch_id')
            moment = _seconds(receipt.get('at'))
            boundary = receipt.get('boundary')
            seen.append((boundary, receipt.get('revision', '')[:12], launch, receipt.get('at')))
            if receipt.get('schema') != 'kogen.feedback-delivery/v1' or \
                    receipt.get('root') != expected_root or receipt.get('session_dir') != expected_session or \
                    receipt.get('intent_id') != intent_id or receipt.get('provider') != harness or \
                    receipt.get('route') != route or \
                    receipt.get('revision') != target or launch not in windows or moment is None or \
                    not (windows[launch][0] <= moment <= windows[launch][1]) or moment >= first_repaired:
                continue
            try:
                payload_bytes = base64.b64decode(receipt.get('payload_base64', ''), validate=True)
                byte_count_ok = len(payload_bytes) == receipt.get('byte_count')
                digest_ok = hashlib.sha256(payload_bytes).hexdigest() == receipt.get('payload_sha256')
                payload = json.loads(payload_bytes.decode('utf-8'))
            except (ValueError, TypeError, UnicodeError):
                continue
            if not byte_count_ok or not digest_ok:
                continue
            delivered = False
            if boundary == 'posttooluse-output':
                if harness == 'claude' or not isinstance(notice_meta, dict) or notice_meta.get('revision') != target:
                    continue
                try:
                    context = payload['hookSpecificOutput']['additionalContext']
                except (KeyError, TypeError):
                    continue
                marker = re.search(r'KOGEN AUDIT\s+\S+\s+' + re.escape(target[:12]) + r'(?:\s|$)', context)
                offered_here = any(o.get('id') == notice_name and o.get('launch_id') == launch
                                  for o in offers)
                delivered = bool(marker and offered_here)
            elif boundary == 'stop-output':
                if not isinstance(payload, dict) or payload.get('decision') != 'block':
                    continue
                reason = payload.get('reason')
                delivered = isinstance(reason, str) and (f'/{target}/report.json' in reason) and \
                    any(item.get('revision') == target for item in stop_blocks)
            if delivered:
                found.append((boundary, target[:12], launch, receipt.get('at'), receipt.get('payload_sha256')))
    return bool(found), (f'blocking findings {targets}; repaired revision first seen '
                         f'{first_repaired}; actual output receipts accepted {found}; receipt candidates {seen}; '
                         f'root launches {sorted(windows)}')

def validate_audit_feedback_delivery(run, revision, events):
    ok, detail = audit_feedback_delivery(run, revision, events)
    reject(ok, f'smoke audit feedback output was not delivered to a root launch before the repair: {detail}')

def validate_smoke_case(evaluation_root):
    """Smoke mode: re-derives the headless-flow outcome from the engine's own
    evidence (status, events, audit reports, config record) instead of trusting
    the driver's smoke-result.json alone."""
    run = case_root(evaluation_root, 'smoke')
    load = lambda name: json.loads((run / name).read_text())
    receipt, messages, delivery = load('review-receipt.json'), load('messages.json'), load('input-delivery.json')
    authored = load('authored-case.json')
    validate_smoke_receipt(receipt)
    authored_messages = authored.get('messages') if isinstance(authored, dict) else None
    reject(isinstance(authored, dict) and set(authored) ==
           {'schema_version', 'name', 'end', 'brief', 'brief_sha256', 'messages'} and
           authored.get('schema_version') == 1 and authored.get('name') == 'headless-flow' and
           authored.get('end') == 'ready' and authored.get('brief') == 'brief.md' and
           isinstance(authored.get('brief_sha256'), str) and
           re.fullmatch(r'[0-9a-f]{64}', authored['brief_sha256']) is not None,
           'smoke authored case snapshot is invalid')
    reject(isinstance(authored_messages, list) and SMOKE_MIN_MESSAGES <= len(authored_messages) <= MAX_SCRIPTED_REPLIES,
           'smoke authored message count is outside its bound')
    reject(isinstance(messages, list) and len(messages) == len(authored_messages) == receipt['scripted_replies'],
           'smoke scripted message count mismatch')
    for index, (message, authored_message) in enumerate(zip(messages, authored_messages), start=1):
        reject(isinstance(authored_message, dict) and set(authored_message) == {'file', 'when', 'sha256'} and
               authored_message.get('file') == f'message-{index}.md' and
               authored_message.get('when') in {'awaiting_answers', 'mid_turn', 'turn_ended'} and
               isinstance(authored_message.get('sha256'), str) and
               re.fullmatch(r'[0-9a-f]{64}', authored_message['sha256']) is not None,
               f'smoke authored message {index} is invalid')
        reject(isinstance(message, dict) and message.get('file') == authored_message['file'] and
               message.get('when') == authored_message['when'] and isinstance(message.get('text'), str) and
               hashlib.sha256(message['text'].encode('utf-8')).hexdigest() == authored_message['sha256'] and
               message.get('request_id') == f'smoke-m{index}',
               f'smoke sent message {index} differs from its authored case')
    reject(authored.get('messages') and authored['messages'][0].get('when') == 'mid_turn' and
           authored['messages'][1].get('when') == 'turn_ended',
           'smoke authored case lost the mid-turn answer or settled follow-up')
    readme = run / 'fixture-source' / 'README.md'
    reject(delivery.get('case') == 'smoke' and delivery.get('available_before_dispatch') is True and
           delivery.get('request_path') == 'README.md' and readme.is_file() and
           delivery.get('readme_sha256') == digest(readme) and
           delivery.get('request') in readme.read_text(), 'smoke initial request was not frozen before dispatch')
    result = load('smoke-result.json')
    checks = result.get('checks') or {}
    reject(result.get('failures') == [] and all(checks.get(name, {}).get('ok') is True for name in SMOKE_CHECKS),
           'smoke checks did not all pass')
    status = load('status-final.json')
    presented = status.get('presented') or {}
    reject(status.get('state') == 'ready' and isinstance(presented.get('id'), str) and
           PRESENTATION_ID.match(presented['id']) is not None, 'smoke session did not end ready with a presentation')
    events = smoke_events(run)
    ids = list(dict.fromkeys(e['provider_session_id'] for e in events if e.get('provider_session_id')))
    turns = [e for e in events if e.get('event') == 'turn_started']
    record = load('config-record.json')
    reject(len(ids) == 1 and (status.get('provider') or {}).get('session_id') == ids[0] and
           record.get('provider_session_ids') == ids, 'smoke provider session ids differ')
    reject(len(turns) >= 2 and any(turn.get('kind') == 'resume' for turn in turns), 'smoke never resumed its provider session')
    reject(record.get('harness') and record.get('route') and record.get('route') == presented.get('route') and
           result.get('route') == record.get('route') and result.get('presentation') == presented.get('id'),
           'smoke route or presentation differs')
    expected_request_ids = ['smoke', *[f'smoke-m{index}' for index in range(1, len(authored_messages) + 1)]]
    reject(record.get('request_ids') == expected_request_ids,
           'smoke request ids differ')
    reports = [json.loads(path.read_text()) for path in sorted((run / 'shaping-audits').glob('*/report.json'))]
    revision = presented.get('revision')
    reject(any(r.get('revision') != revision and r.get('findings') for r in reports),
           'no earlier revision had an audit finding')
    final = load('presented-report.json')
    reject(revision and final.get('revision') == revision and final.get('scope') == 'full' and final.get('readiness') == 'ready' and
           any(r.get('revision') == revision and r.get('scope') == 'full' and r.get('readiness') == 'ready' for r in reports),
           'the presented report is not a ready full report of the final revision')
    identity = draft_identity(run / 'draft')
    reject(all((run / 'draft' / name).is_file() for name in ('scenarios.yaml', 'questions.md')), 'saved smoke Draft contract files missing')
    answers = re.search(r'(?m)^## Shaper answers[ \t]*\n(.*?)(?=^## |\Z)', (run / 'draft' / 'questions.md').read_text(), re.S)
    validate_first_answer_delivery(run, messages[0], events, answers.group(1) if answers else '')
    validate_audit_feedback_delivery(run, revision, events)
    reject(not (run / 'draft' / 'approval.md').exists(), 'smoke Draft was approved')
    return identity

def validate_smoke_manifest(root, manifest_path):
    trace_path = os.environ.get("KOGEN_REHEARSAL_TRACE")
    if trace_path:
        with open(trace_path, "a", encoding="utf-8") as trace:
            trace.write("Kogen.ShapingEvaluation.Integrity.validate_smoke_manifest\n")
    payload = json.loads(manifest_path.read_text())
    reject(set(payload) == {'schema_version', 'required_evidence'} and payload['schema_version'] == 1, 'manifest schema')
    entries = payload['required_evidence']
    reject(isinstance(entries, list) and entries, 'required evidence is empty')
    seen = set()
    for entry in entries:
        reject(set(entry) == {'path', 'sha256'}, 'invalid manifest entry')
        path = relative_safe(root, entry['path'])
        reject(entry['path'] not in seen, 'duplicate evidence path'); seen.add(entry['path'])
        reject(isinstance(entry['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', entry['sha256']) is not None, 'invalid evidence hash')
        reject(digest(path) == entry['sha256'], 'evidence hash mismatch')
        parts = Path(entry['path']).parts
        reject('owned-rollouts' not in parts and 'private-raw-rollouts' not in parts,
               'manifest includes private rollout stream')
        reject(Path(entry['path']).name not in {'receipt.json', 'transport.log', 'pty.log'} and
               not Path(entry['path']).name.startswith('resume-') and not Path(entry['path']).name.endswith('-pty.log'),
               'manifest includes private runtime log or detailed receipt')
    evaluation_root = manifest_path.parent
    run = case_root(evaluation_root, 'smoke')
    names = ('config-record.json', 'engine-run.json', 'status-final.json', 'messages.json', 'authored-case.json', 'smoke-result.json',
             'review-receipt.json', 'input-delivery.json', 'presented-report.json', 'engine-runtime/events.jsonl',
             'feedback-delivery/receipts.jsonl',
             'draft/intent.yaml', 'draft/scenarios.yaml', 'draft/questions.md')
    required = [run / name for name in names]
    required.extend(sorted((run / 'shaping-audits').glob('*/report.json')))
    required.extend(sorted((run / 'shaping-audits').glob('hook.jsonl')))
    required.extend(sorted(path for path in (run / 'engine-runtime' / 'notices').glob('*') if path.is_file()))
    required.extend(path for path in (run / 'draft').rglob('*') if path.is_file())
    reject(all(path.is_file() and str(path.resolve().relative_to(root.resolve())) in seen for path in required),
           'manifest omits required smoke evidence')
    validate_smoke_case(evaluation_root)
    return payload

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
        unresolved = '?' in partial or 'unresolved' in partial or 'awaiting explicit' in partial
        reject('output' in partial and any(term in partial for term in ('replace', 'replacement', 'overwrite')) and unresolved, 'CSV continuation partial assent did not preserve the remaining output replacement question')
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
    if case.startswith('stateful-'):
        control_path = run / 'stateful-control-result.json'
        reject(control_path.is_file(), 'stateful deterministic control result missing')
        control = json.loads(control_path.read_text())
        reject(control.get('mode') == ('complete' if case.endswith('complete') else 'flawed'),
               'stateful control mode mismatch')
        reject(control.get('source_sha256'), 'stateful source identity missing from control')
        cycles = control.get('cycles', [])
        reject(len(cycles) == 2 and all(item.get('dispatched') is True for item in cycles),
               'stateful failed cycles did not dispatch')
        corrupted, exhausted, repair = (control.get(key, {}) for key in ('corrupt_state', 'exhausted_replay', 'repair'))
        if case.endswith('flawed'):
            reject(corrupted.get('dispatched') is True and exhausted.get('dispatched') is True,
                   'flawed stateful route did not expose unsafe dispatch')
        else:
            reject(corrupted.get('dispatched') is False and exhausted.get('dispatched') is False,
                   'complete stateful route dispatched on invalid or exhausted state')
        reject(repair.get('ok') is True and repair.get('dispatched') is True,
               'stateful valid repair did not succeed')
        consumer = control.get('receipt_consumer', {})
        reject(consumer.get('accepted') is (case.endswith('complete')),
               'stateful receipt consumer result mismatch')
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
    trace_path = os.environ.get("KOGEN_REHEARSAL_TRACE")
    if trace_path:
        with open(trace_path, "a", encoding="utf-8") as trace:
            trace.write("Kogen.ShapingEvaluation.Integrity.validate_manifest\n")
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
        if case.startswith('stateful-'): required.append(f'{relative_root}/runs/{case}/stateful-control-result.json')
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

def validate_failure_manifest(root, manifest_path):
    """Failure-mode manifest: no-cancel suite failures manifest whatever each
    case already produced plus suite-failure.json itself, never a full
    per-case coverage requirement (some cases may be cancelled/incomplete)."""
    payload = json.loads(manifest_path.read_text())
    reject(set(payload) == {'schema_version', 'required_evidence'} and payload['schema_version'] == 1,
           'manifest schema')
    entries = payload['required_evidence']
    reject(isinstance(entries, list) and entries, 'required evidence is empty')
    seen = set()
    suite_failure_seen = False
    for entry in entries:
        reject(set(entry) == {'path', 'sha256'}, 'invalid manifest entry')
        path = relative_safe(root, entry['path'])
        reject(entry['path'] not in seen, 'duplicate evidence path'); seen.add(entry['path'])
        reject(isinstance(entry['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', entry['sha256']) is not None,
               'invalid evidence hash')
        reject(path.is_file(), f"failure manifest entry does not exist: {entry['path']}")
        reject(digest(path) == entry['sha256'], 'evidence hash mismatch')
        parts = Path(entry['path']).parts
        reject('owned-rollouts' not in parts and 'private-raw-rollouts' not in parts,
               'manifest includes private rollout stream')
        reject(Path(entry['path']).name not in {'receipt.json', 'transport.log', 'pty.log'} and
               not Path(entry['path']).name.startswith('resume-') and not Path(entry['path']).name.endswith('-pty.log'),
               'manifest includes private runtime log or detailed receipt')
        if Path(entry['path']).name == 'suite-failure.json':
            suite_failure_seen = True
    reject(suite_failure_seen, 'failure manifest omits suite-failure.json')
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
        if case.startswith('stateful-'):
            complete = case.endswith('complete')
            result = {'mode': 'complete' if complete else 'flawed', 'source_sha256': 'a' * 64,
                      'cycles': [{'dispatched': True}, {'dispatched': True}],
                      'corrupt_state': {'dispatched': not complete},
                      'exhausted_replay': {'dispatched': not complete},
                      'repair': {'ok': True, 'dispatched': True},
                      'receipt_consumer': {'accepted': complete}}
            write(run/'stateful-control-result.json', json.dumps(result))
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
    parser=argparse.ArgumentParser(); parser.add_argument('--self-test',action='store_true'); parser.add_argument('--validate-manifest'); parser.add_argument('--root')
    parser.add_argument('--smoke', action='store_true', help='validate the standalone smoke manifest instead of the CASES suite manifest')
    options=parser.parse_args()
    if options.self_test: self_test()
    elif options.validate_manifest:
        if not options.root: parser.error('--validate-manifest requires --root')
        if options.smoke:
            validate_smoke_manifest(Path(options.root),Path(options.validate_manifest))
        else:
            validate_manifest(Path(options.root),Path(options.validate_manifest))
        print('shaping evaluation manifest: valid')
