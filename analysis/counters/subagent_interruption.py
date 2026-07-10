"""Counter (repo-level): scan cycle logs for subagent-death thrash events."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Dict, List, Optional

from analysis.config import Config
from analysis.counters import Finding
from analysis.window import in_window

# died-event kind -> (pattern_key, wasted_turns)
# interrupted: drop+respawn = 2; aborted: drop-twice+halt = 3.
_KIND_WEIGHTS: Dict[str, int] = {
    "interrupted": 2,
    "aborted": 3,
}

# Filename fallback date source: leading YYYYMMDD_ prefix on *_cycle.jsonl.
_FILENAME_DATE_RE = re.compile(r"^(\d{4})(\d{2})(\d{2})_")


def _file_date(text: str, filename: str) -> Optional[str]:
    """Resolve a cycle log's date as an ISO-8601 string, or None if undatable.

    died events carry no per-event ts, so the whole file is dated once:
    primary source is the `init` line's `stamp.at`; fallback is the
    filename's leading `YYYYMMDD_` prefix. Both absent/unparseable -> None
    (fail-closed — the caller drops the entire file).
    """
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("ev") == "init":
            stamp_at = obj.get("stamp", {}).get("at")
            if stamp_at:
                return stamp_at
        break  # init, if present, is always the first line

    m = _FILENAME_DATE_RE.match(filename)
    if m:
        year, month, day = m.groups()
        return f"{year}-{month}-{day}T00:00:00Z"
    return None


def run_repo(config: Config) -> List[Finding]:
    """Scan <logging_dir>/*_cycle.jsonl for {"ev":"died"} events.

    Repo-level (NOT per-session) so events are counted once, not once per
    transcript.  Returns [] gracefully when the logging dir is absent.
    Malformed (non-JSON) lines are skipped — a cycle log is an append-only
    file and may be read mid-write; a bad line is a boundary condition, not
    a bug, so it is fail-open skipped rather than crashing the counter.

    Each file is dated ONCE (died events carry no per-event ts) via
    `_file_date`; a file whose date is undatable or out-of-window is
    fail-closed dropped in its entirety before its died events are scanned.
    """
    logging_dir = _logging_dir(config)
    if not logging_dir.exists():
        return []

    findings: List[Finding] = []
    for log_path in sorted(logging_dir.glob("*_cycle.jsonl")):
        try:
            text = log_path.read_text(encoding="utf-8")
        except OSError:
            continue
        file_date = _file_date(text, log_path.name)
        if not in_window(file_date, config.since):
            continue
        session_id = log_path.name
        for lineno, line in enumerate(text.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if obj.get("ev") != "died":
                continue
            kind = obj.get("kind")
            wasted = _KIND_WEIGHTS.get(kind)
            if wasted is None:
                continue
            findings.append(
                Finding(
                    counter="subagent_interruption",
                    pattern_key=kind,
                    session_id=session_id,
                    turn_index=lineno,
                    wasted_turns=wasted,
                    evidence=line,
                )
            )
    return findings


def _logging_dir(config: Config) -> Path:
    """Resolve session-log dir: project_dir (test) or codegen_dir/codegen/logging.

    Mirrors hook_intervention._substrate_root so the test seam is identical.
    """
    if config.project_dir is not None:
        return Path(config.project_dir)
    return config.codegen_dir / "codegen" / "logging"
