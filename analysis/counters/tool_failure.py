"""Counter (repo-level): aggregate real tool-failure waste from failures/*.jsonl.

Repo-level (NOT per-session) — the substrate is a flat, repo-wide log, not a
per-session transcript. Scanning it once per session (the prior `run` shape)
multiplied every finding's wasted_turns by the session count. See
subagent_interruption.run_repo for the sanctioned repo-level pattern this
module mirrors.
"""
from __future__ import annotations

import datetime
import json
from collections import Counter
from pathlib import Path
from typing import List, Optional, Tuple

from analysis.config import Config
from analysis.counters import Finding

# Waste taxonomy: (tool, error-substring-match) -> waste_class.
# Only classes returned here count as real, fixable waste. Everything else
# (interrupted, missing-file, infra, forbidden-guard-hit, bare exit signal)
# is expected/benign/already-counted-elsewhere and is excluded.
_WASTE_SIGNATURES: List[Tuple[str, str]] = [
    ("oversized-read", "Read exceeds"),
    ("oversized-read", "token"),
    ("dir-read", "EISDIR"),
    ("dir-read", "Is a directory"),
    ("bad-arg", "unsupported"),
    ("bad-arg", "Unsupported"),
    ("bad-arg", "invalid option"),
    ("bad-arg", "illegal option"),
    ("agent-not-found", "not found"),
]

# Error substrings that mark forbidden-guard hits — already counted by the
# transcript-scanning forbidden_bash counter. Excluded here to avoid
# double-counting the same waste under two counters.
_GUARD_HIT_SIGNATURES: List[str] = [
    "illegal option",  # cat: illegal option
    "usage: cat",
]

# Error substrings that mark expected/benign/infra failures — never waste.
_EXPECTED_SIGNATURES: List[str] = [
    "Request interrupted by user",
    "File does not exist",
    "timeout",
    "Timeout",
    "quota",
    "limit",
]


def _classify(tool: str, error: str) -> Tuple[str, bool]:
    """Classify a failure record -> (waste_class, is_waste).

    Order matters: guard-hit and expected signatures are checked BEFORE the
    waste signatures so an error string matching both a benign pattern and a
    coincidental waste substring is excluded, not double-counted.
    """
    for sig in _GUARD_HIT_SIGNATURES:
        if sig in error:
            return "guard-hit", False
    for sig in _EXPECTED_SIGNATURES:
        if sig in error:
            return "expected", False
    for waste_class, sig in _WASTE_SIGNATURES:
        if sig in error:
            return waste_class, True
    return "exit-signal", False


def _parse_ts(value: str) -> Optional[datetime.datetime]:
    """Parse an ISO-8601 `ts` string (e.g. `...Z`) -> aware datetime, or None."""
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _run_group_file(
    records: List[dict], config: Config
) -> List[Tuple[str, int, str]]:
    """Group one file's genuine-waste records into runs of consecutive same
    `{tool}×{waste_class}` records with inter-record `ts` gap below
    `config.spiral_gap_seconds`.

    Returns a list of (pattern_key, weight, evidence) tuples: one entry per
    run. A run of length >= spiral_min_run becomes a single `:spiral` entry
    weighted `run_length * 2`; a run of length 1 (isolated, or unparseable
    ts — fail-safe) becomes a base-key entry weighted 1 (the parent's flat
    behavior, preserved).

    Records must already be filtered to genuine waste and given in file
    (append) order.
    """
    entries: List[Tuple[str, int, str]] = []
    run_key: Optional[str] = None
    run_records: List[dict] = []
    run_last_ts: Optional[datetime.datetime] = None

    def _flush() -> None:
        if not run_records:
            return
        base_key = run_key
        evidence = run_records[0]["_line"][:120]
        run_len = len(run_records)
        if run_len >= config.spiral_min_run:
            entries.append((f"{base_key}:spiral", run_len * 2, evidence))
        else:
            entries.append((base_key, 1, evidence))

    for record in records:
        tool = record.get("tool", "unknown")
        error = record.get("error", "")
        waste_class, is_waste = _classify(tool, error)
        if not is_waste:
            continue
        key = f"{tool}×{waste_class}"
        ts = _parse_ts(record.get("ts", ""))

        same_run = (
            run_key == key
            and ts is not None
            and run_last_ts is not None
            and (ts - run_last_ts).total_seconds() <= config.spiral_gap_seconds
        )

        if same_run:
            run_records.append(record)
        else:
            _flush()
            run_key = key
            run_records = [record]

        run_last_ts = ts

    _flush()
    return entries


def run_repo(config: Config) -> List[Finding]:
    """Scan failures/*.jsonl once (repo-level); return [] gracefully when absent."""
    failures_dir = _failures_dir(config)
    if not failures_dir.exists():
        return []

    pattern_counts: Counter[str] = Counter()
    pattern_sessions: dict = {}
    pattern_first_line: dict = {}

    for jsonl_path in sorted(failures_dir.glob("*.jsonl")):
        session_id = jsonl_path.stem
        file_records: List[dict] = []
        try:
            with open(jsonl_path, encoding="utf-8") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        record = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    record["_line"] = line
                    file_records.append(record)
        except OSError:
            continue

        for key, weight, evidence in _run_group_file(file_records, config):
            pattern_counts[key] += weight
            pattern_sessions.setdefault(key, set()).add(session_id)
            if key not in pattern_first_line:
                pattern_first_line[key] = evidence

    # Attribute the full wasted-turns count once, under the first session
    # seen for that pattern, so _cluster's sum(wasted_turns) equals the real
    # weighted count exactly (not count × distinct-session-count). Emit
    # zero-weight findings for the remaining sessions so the cluster's
    # session-count still reflects every session that hit the pattern.
    findings: List[Finding] = []
    for key, count in pattern_counts.items():
        sessions = sorted(pattern_sessions[key])
        findings.append(
            Finding(
                counter="tool_failure",
                pattern_key=key,
                session_id=sessions[0],
                turn_index=-1,
                wasted_turns=count,
                evidence=pattern_first_line.get(key, ""),
            )
        )
        # Emit zero-weight findings for the remaining sessions so the
        # cluster's session-count reflects every session that hit this
        # pattern, without inflating wasted_turns.
        for session_id in sessions[1:]:
            findings.append(
                Finding(
                    counter="tool_failure",
                    pattern_key=key,
                    session_id=session_id,
                    turn_index=-1,
                    wasted_turns=0,
                    evidence=pattern_first_line.get(key, ""),
                )
            )
    return findings


def failures_present(config: Config) -> bool:
    """Return True if the failures substrate directory exists."""
    return _failures_dir(config).exists()


def _failures_dir(config: Config) -> Path:
    """Resolve failures directory."""
    if config.project_dir is not None:
        # In test mode with project_dir, look for a 'failures' subdir or use project_dir itself
        subdir = Path(config.project_dir) / "failures"
        if subdir.exists():
            return subdir
        # Fall back: check if project_dir has failures.jsonl directly
        # For tests, we place failures.jsonl in project_dir directly
        return Path(config.project_dir)
    return config.codegen_dir / "codegen" / "logging" / "failures"
