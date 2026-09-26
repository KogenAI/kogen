#!/usr/bin/env python3
"""P5 signature prototype: 'frame' and 'fallback' signatures for failed receipts.

frame  = offline.py failing stage identity + first failing ExUnit test id
         (name/module/file:line) + first assertion line, hashed.
fallback = last N nonblank lines of output, normalized (ANSI stripped, ExUnit
           seed/timestamps/durations/tmp paths/hex digests/codex warning
           lines removed), hashed.
"""
import hashlib
import json
import re
import sys
from pathlib import Path

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')
SEED_RE = re.compile(r'(--seed\s+\d+|Randomized with seed\s+\d+)')
DURATION_RE = re.compile(r'\bFinished in [0-9.]+ seconds[^\n]*')
NUM_SECONDS_RE = re.compile(r'\b\d+(\.\d+)?s\b')
ISO_TS_RE = re.compile(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z?')
TMP_PATH_RE = re.compile(
    r'(/private/tmp/\S*|/var/folders/\S*|\S*compatibility-\d+-\d+\S*)'
)
ISOLATED_TOKEN_RE = re.compile(r'KOGEN_ISOLATED_COMPLETION\t\S+.*$', re.M)
HEX_DIGEST_RE = re.compile(r'\b[0-9a-f]{12,}\b')
CODEX_BYPASS_RE = re.compile(r'.*--dangerously-bypass-hook-trust.*\n?')
STAGE_ELAPSED_RE = re.compile(r'^Stage elapsed \((.+?)\):\s*([0-9.]+)s$', re.M)
EXUNIT_TEST_RE = re.compile(
    r'^[ \t]*(\d+)\)[ \t]+(test .+?)[ \t]+\((\S+)\)[ \t]*\n[ \t]*(\S+\.exs?:\d+)', re.M
)


def strip_ansi(text):
    return ANSI_RE.sub('', text)


def normalize_for_fallback(text):
    text = strip_ansi(text)
    text = SEED_RE.sub('<SEED>', text)
    text = DURATION_RE.sub('Finished in <DURATION>', text)
    text = NUM_SECONDS_RE.sub('<DUR>s', text)
    text = ISO_TS_RE.sub('<TS>', text)
    text = TMP_PATH_RE.sub('<TMPPATH>', text)
    text = ISOLATED_TOKEN_RE.sub('KOGEN_ISOLATED_COMPLETION <NORMALIZED>', text)
    text = HEX_DIGEST_RE.sub('<HEX>', text)
    text = CODEX_BYPASS_RE.sub('', text)
    return text


def last_nonblank_lines(text, n=20):
    lines = [l for l in text.splitlines() if l.strip()]
    return lines[-n:]


def fallback_signature(output, n=20):
    normalized = normalize_for_fallback(output)
    tail = last_nonblank_lines(normalized, n)
    joined = "\n".join(tail)
    digest = hashlib.sha256(joined.encode('utf-8', 'replace')).hexdigest()
    return digest, tail


def find_failing_stage(output):
    """Return (stage_command, index_in_text) for the failing offline.py stage.

    offline.py prints 'Stage elapsed (<command>): Xs' after every stage
    (pass or fail) in STAGE order. The stage immediately preceding the first
    ExUnit failure block / non-zero exit report is the failing one. Since
    'Stage elapsed' lines appear for *all* stages including passing ones, we
    take the LAST 'Stage elapsed' line that appears BEFORE the first ExUnit
    failure marker ('\\n  1) test') or 'Error 1'/'Error 2' (make failure);
    if no ExUnit failure marker exists but there's a trailing incomplete
    stage (crash before its own elapsed-print), we fall back to the stage
    whose command follows the last completed 'Stage elapsed' entry (a '+
    <command>' line with no matching elapsed line after it = the one that
    crashed/timed out).
    """
    stage_matches = list(STAGE_ELAPSED_RE.finditer(output))
    first_fail_idx = None
    m = re.search(r'^\s*\d+\)\s+test ', output, re.M)
    if m:
        first_fail_idx = m.start()
    plus_matches = list(re.finditer(r'^\+ (.+)$', output, re.M))
    if first_fail_idx is not None:
        # offline.py prints a stage's captured stdout (incl. any ExUnit
        # failure text) BEFORE printing that stage's own "Stage elapsed"
        # line, so the failing stage is the first elapsed-line AFTER the
        # first failure marker.
        after = [sm for sm in stage_matches if sm.start() > first_fail_idx]
        if after:
            return after[0].group(1)
        # Failure text appears but no later elapsed line completed: the
        # stage crashed/timed out before printing its own elapsed line.
        started_before = [pm for pm in plus_matches if pm.start() < first_fail_idx]
        return started_before[-1].group(1) if started_before else None
    # No ExUnit failure text (e.g. compile/credo/format failure, or a
    # PTY/timeout crash): the failing stage is whichever "+ <command>"
    # started without a matching later "Stage elapsed" line, i.e. the
    # count of completed elapsed-lines is less than started stages.
    if plus_matches and len(plus_matches) > len(stage_matches):
        return plus_matches[len(stage_matches)].group(1)
    return stage_matches[-1].group(1) if stage_matches else None


def find_first_failing_test(output):
    m = EXUNIT_TEST_RE.search(output)
    if not m:
        return None
    _, test_name, module, location = m.groups()
    return f"{test_name} ({module}) {location}"


def find_first_assertion_line(output, after_idx=0):
    """Return the first informative reason line after a failing test's
    header. Isolated-process tests nest a wrapper line ("isolated test ...
    failed (...)") plus a re-run banner before the real nested failure
    block; skip past those to the actual reason (which may be a bare
    freeform message like "pty success: terminal probe failed: ..." rather
    than one of ExUnit's own "code:"/"left:"/"right:"/"** (" markers).
    """
    tail = output[after_idx:]
    lines = tail.splitlines()
    idx = 0
    # Skip blank lines and the isolated-process wrapper/banner lines.
    skip_prefixes = ("isolated test ", "Running ExUnit", "Excluding tags",
                      "Including tags")
    while idx < len(lines):
        line = lines[idx].strip()
        if not line:
            idx += 1
            continue
        if any(line.startswith(p) for p in skip_prefixes):
            idx += 1
            continue
        break
    # If we're sitting on a nested "N) test ..." + location header (the
    # isolated re-run reproduces the same failure), skip past it too.
    if idx < len(lines) and re.match(r'^\d+\)\s+test ', lines[idx].strip()):
        idx += 1
        while idx < len(lines) and not lines[idx].strip():
            idx += 1
        if idx < len(lines) and re.match(r'^\S+\.exs?:\d+', lines[idx].strip()):
            idx += 1
    while idx < len(lines) and not lines[idx].strip():
        idx += 1
    return lines[idx].strip() if idx < len(lines) else None


def frame_signature(output):
    stage = find_failing_stage(output)
    test_match = EXUNIT_TEST_RE.search(output)
    test_id = None
    assertion = None
    if test_match:
        _, test_name, module, location = test_match.groups()
        test_id = f"{test_name} ({module}) {location}"
        assertion = find_first_assertion_line(output, test_match.end())
    parts = f"stage={stage}\ntest={test_id}\nassertion={assertion}"
    digest = hashlib.sha256(parts.encode('utf-8', 'replace')).hexdigest()
    return digest, stage, test_id, assertion


def load_failed_receipts(state_history_path):
    """Yield (cycle_index, target, receipt) for every failed receipt across
    the cycles recorded in the LAST snapshot line of a state-history.jsonl.
    """
    lines = Path(state_history_path).read_text().splitlines()
    if not lines:
        return
    last = json.loads(lines[-1])
    for cycle in last.get('cycles', []):
        for receipt in cycle.get('receipts', []):
            if receipt.get('status') == 'failed':
                yield cycle.get('sequence'), receipt.get('target'), receipt


def record_today_digest(record_path):
    rec = json.loads(Path(record_path).read_text())
    for a in rec.get('attempts', []):
        f = a.get('failure')
        if not f:
            continue
        m = re.search(r'"digest":"([0-9a-f]+)"', f)
        if m:
            return m.group(1)
    return None


if __name__ == '__main__':
    root = Path('/Users/almirsarajcic/Areas/Kogen/kogen/.kogen/runtime/scenario-tracking')
    builds = {
        'ZJDgU9wo': root / 'ZJDgU9wor-7VkDjy8DckWvXA',
        '_8Qpvuip': root / '_8QpvuipdJ9PYvl3NKP3KgjG',
        'a2sPFUvF': root / 'a2sPFUvFlBoNtimOp1psV5Ui',
        'hAOGGjSC': root / 'hAOGGjSCl08DLSUS-OR-CAcG',
        'btwokrNx': root / 'btwokrNxL50md1z5Fb-GGYOO',
        'Bg1qobsC': root / 'Bg1qobsC2dxFq02go76WwTKn',
    }
    rows = []
    for label, bdir in builds.items():
        history_files = sorted(bdir.glob('verification/*/state-history.jsonl'))
        today_digest = record_today_digest(bdir / 'record.json')
        for hf in history_files:
            for cyc, target, receipt in load_failed_receipts(hf):
                out = receipt.get('output', '')
                fsig, stage, test_id, assertion = frame_signature(out)
                fbdig, tail = fallback_signature(out, n=20)
                rows.append({
                    'build': label,
                    'attempt_dir': hf.parent.name,
                    'cycle': cyc,
                    'target': target,
                    'today_digest': today_digest,
                    'frame_sig': fsig[:16],
                    'fallback_sig': fbdig[:16],
                    'stage': stage,
                    'test_id': test_id,
                    'assertion': assertion,
                    'out_len': len(out),
                })
    for r in rows:
        print(json.dumps(r))
