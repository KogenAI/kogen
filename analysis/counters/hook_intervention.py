"""Counter: detect hook-intervention signals in transcripts and substrate.

Two legs, two scopes:
  - Transcript leg (`run`): per-session scan of "Stop hook feedback:" user
    turns. Stays per-session — it's derived from that session's transcript.
  - Gate-verdicts leg (`run_repo`): repo-level scan of gate-verdicts.jsonl,
    attributed via each record's own session_id field. Moved out of `run`
    because scanning the repo-wide substrate once per session multiplied
    every finding's wasted_turns by the session count.
"""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.window import in_window
from analysis.turn_window import evidence_snippet

# Prefix that durable hook feedback messages carry in user turns
_HOOK_FEEDBACK_PREFIX = "Stop hook feedback:"

# Regex: "Stop hook feedback: <rule-name> ..."
_RULE_NAME_RE = re.compile(r"Stop hook feedback:\s*([^\s—:]+)")

# Rule names excluded from waste counting:
#   - stop-gate-failure-breaker: fires only after >=3 REAL gate failures
#     (stop-gate-failure-breaker.sh's own guard: `failed_count>=3 && verdict==failed`).
#     Those failures are already counted by the gate-verdicts substrate leg;
#     counting the breaker's escalation too is a double-count of the same
#     underlying waste, and the escalation itself is the system working
#     correctly, not fresh agent waste.
#   - step-log-completeness: rule removed in the 2026-07-06 JSONL migration.
#     Any surviving feedback referencing it is stale, not live waste.
_EXCLUDED_RULES = {
    "stop-gate-failure-breaker",
    "step-log-completeness",
}


def _classify_intervention(rule_name: str) -> bool:
    """Return True if this rule's intervention counts as real waste."""
    return rule_name not in _EXCLUDED_RULES


def run(session: Session, config: Config) -> List[Finding]:
    """Find hook-intervention findings from the session transcript."""
    findings: List[Finding] = []

    for turn in session.turns:
        if turn.user_text and turn.user_text.startswith(_HOOK_FEEDBACK_PREFIX):
            m = _RULE_NAME_RE.match(turn.user_text)
            rule_name = m.group(1) if m else "unknown"
            if not _classify_intervention(rule_name):
                continue
            evidence = evidence_snippet(session.turns, turn.index, config.window)
            findings.append(
                Finding(
                    counter="hook_intervention",
                    pattern_key=rule_name,
                    session_id=session.session_id,
                    turn_index=turn.index,
                    wasted_turns=1,
                    evidence=evidence,
                )
            )

    return findings


def run_repo(config: Config) -> List[Finding]:
    """Scan gate-verdicts.jsonl once (repo-level); return [] gracefully when absent."""
    substrate_root = _substrate_root(config)
    gate_verdicts_path = substrate_root / "gate-verdicts.jsonl"
    if not gate_verdicts_path.exists():
        return []

    findings: List[Finding] = []
    try:
        with open(gate_verdicts_path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if record.get("verdict") != "failed":
                    continue
                if not in_window(record.get("started"), config.since):
                    continue
                session_id = record["session_id"]
                findings.append(
                    Finding(
                        counter="hook_intervention",
                        pattern_key="gate:failed",
                        session_id=session_id,
                        turn_index=-1,  # substrate record, no turn index
                        wasted_turns=2,
                        evidence=f"gate-verdicts.jsonl: {line[:100]}",
                    )
                )
    except OSError:
        pass

    return findings


def substrate_present(config: Config) -> bool:
    """Return True if the gate-verdicts substrate file exists."""
    return (_substrate_root(config) / "gate-verdicts.jsonl").exists()


def _substrate_root(config: Config) -> Path:
    """Resolve substrate directory: project_dir (test) or codegen_dir/codegen/logging."""
    if config.project_dir is not None:
        return Path(config.project_dir)
    return config.codegen_dir / "codegen" / "logging"
