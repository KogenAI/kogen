"""Probe the maintained evaluation consumer with synthetic session files only."""
import hashlib, importlib.util, json, os, tempfile
from pathlib import Path

root = Path.cwd()
source = root / 'test/support/shaping_evaluation/driver.py'
output = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='owned-', dir=output) as scratch:
    private = Path(scratch)
    caller = private / 'caller'
    managed = private / 'managed'
    fixture = private / 'fixture'
    fixture.mkdir()
    personal_sessions = caller / '.codex/sessions'
    managed_sessions = managed / 'sessions'
    for directory in (personal_sessions, managed_sessions):
        directory.mkdir(parents=True)
    saved = {key: os.environ.get(key) for key in ('HOME', 'CODEX_HOME', 'KOGEN_SHAPING_EVALUATION_RUNTIME')}
    os.environ.update(HOME=str(caller), CODEX_HOME=str(managed), KOGEN_SHAPING_EVALUATION_RUNTIME=str(private/'runtime'))
    try:
        spec = importlib.util.spec_from_file_location('current_driver_probe', source)
        driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(driver)
        record = json.dumps({'type':'session_meta','payload':{'id':'synthetic-root','cwd':str(fixture),'source':'cli'}})+'\n'
        (managed_sessions/'rollout-managed.jsonl').write_text(record)
        missed_managed = driver.exact_root_rollout(set(), fixture) == []
        (personal_sessions/'rollout-personal.jsonl').write_text(record)
        personal_control = len(driver.exact_root_rollout(set(), fixture)) == 1
        driver.SESSION_ROOT = managed_sessions
        injected_control = driver.exact_root_rollout(set(), fixture) == [str(managed_sessions/'rollout-managed.jsonl')]
        result = {'kind':'source-bound-synthetic-consumer-probe','source':str(source.relative_to(root)), 'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),'managed_session_missed_by_current_default':missed_managed,'personal_location_positive_control':personal_control,'explicit_managed_root_positive_control':injected_control,'provider_calls':0,'production_writes':0,'limits':'Session discovery only; no native launch, authentication, resume, full rehearsal or Build acceptance.'}
        assert missed_managed and personal_control and injected_control
    finally:
        for key,value in saved.items():
            if value is None: os.environ.pop(key,None)
            else: os.environ[key]=value
(output/'results.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
