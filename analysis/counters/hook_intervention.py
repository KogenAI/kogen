"""Counter: detect hook-intervention signals in transcripts and substrate."""
from __future__ import annotations

import json
import re
from pathlib import Path
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.turn_window import evidence_snippet

# Prefix that durable hook feedback messages carry in user turns
_HOOK_FEEDBACK_PREFIX = "Stop hook feedback:"

# Regex: "Stop hook feedback: <rule-name> ..."
_RULE_NAME_RE = re.compile(r"Stop hook feedback:\s*([^\s—:]+)")


def run(session: Session, config: Config) -> List[Finding]:
    """Find hook-intervention findings from transcript + substrate."""
    findings: List[Finding] = []

    # Transcript: scan user turns for hook feedback prefix
    for turn in session.turns:
        if turn.user_text and turn.user_text.startswith(_HOOK_FEEDBACK_PREFIX):
            m = _RULE_NAME_RE.match(turn.user_text)
            rule_name = m.group(1) if m else "unknown"
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

    # Substrate: gate-verdicts.jsonl (if present)
    substrate_root = _substrate_root(config)
    gate_verdicts_path = substrate_root / "gate-verdicts.jsonl"
    if gate_verdicts_path.exists():
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
                    if record.get("verdict") == "failed":
                        findings.append(
                            Finding(
                                counter="hook_intervention",
                                pattern_key="gate:failed",
                                session_id=session.session_id,
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
