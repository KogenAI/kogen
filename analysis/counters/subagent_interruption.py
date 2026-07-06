"""Counter (repo-level): scan cycle logs for subagent-death thrash events."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Dict, List

from analysis.config import Config
from analysis.counters import Finding

# died-event kind -> (pattern_key, wasted_turns)
# interrupted: drop+respawn = 2; aborted: drop-twice+halt = 3.
_KIND_WEIGHTS: Dict[str, int] = {
    "interrupted": 2,
    "aborted": 3,
}


def run_repo(config: Config) -> List[Finding]:
    """Scan <logging_dir>/*_cycle.jsonl for {"ev":"died"} events.

    Repo-level (NOT per-session) so events are counted once, not once per
    transcript.  Returns [] gracefully when the logging dir is absent.
    Malformed (non-JSON) lines are skipped — a cycle log is an append-only
    file and may be read mid-write; a bad line is a boundary condition, not
    a bug, so it is fail-open skipped rather than crashing the counter.
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
