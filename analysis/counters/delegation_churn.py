"""Counter: detect Agent/Task spawns with missing step-log correlation."""
from __future__ import annotations

from pathlib import Path
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.turn_window import evidence_snippet


def run(session: Session, config: Config) -> List[Finding]:
    """Count Agent/Task tool spawns; flag when no step-log is found in codegen/logging."""
    findings: List[Finding] = []

    # Collect Agent/Task spawns
    spawns: List[int] = []
    for turn in session.turns:
        for tu in turn.tool_uses:
            if tu.name in ("Agent", "Task"):
                spawns.append(turn.index)

    if not spawns:
        return []

    # Check for step-log presence
    log_dir = _log_dir(config)
    step_logs = _count_step_logs(log_dir)

    if step_logs == 0:
        # No step logs found — emit one Finding per spawn
        for turn_idx in spawns:
            evidence = evidence_snippet(session.turns, turn_idx, config.window)
            findings.append(
                Finding(
                    counter="delegation_churn",
                    pattern_key="delegation:no-step-log",
                    session_id=session.session_id,
                    turn_index=turn_idx,
                    wasted_turns=1,
                    evidence=evidence,
                )
            )

    return findings


def _log_dir(config: Config) -> Path:
    """Resolve log directory: project_dir (test) or codegen_dir/codegen/logging."""
    if config.project_dir is not None:
        return Path(config.project_dir)
    return config.codegen_dir / "codegen" / "logging"


def _count_step_logs(log_dir: Path) -> int:
    """Count cycle log JSONL files in the log directory."""
    if not log_dir.exists():
        return 0
    count = 0
    for p in log_dir.iterdir():
        if p.name.endswith("_cycle.jsonl"):
            count += 1
    return count
