"""Counter: aggregate tool failures from substrate failures/*.jsonl (graceful if absent)."""
from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session


def run(session: Session, config: Config) -> List[Finding]:
    """Read failures substrate; return [] gracefully when absent."""
    failures_dir = _failures_dir(config)
    if not failures_dir.exists():
        return []

    pattern_counts: Counter[str] = Counter()
    pattern_first_line: dict = {}

    for jsonl_path in sorted(failures_dir.glob("*.jsonl")):
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
                    tool = record.get("tool", "unknown")
                    role = record.get("role", "unknown")
                    key = f"{tool}×{role}"  # × separator
                    pattern_counts[key] += 1
                    if key not in pattern_first_line:
                        pattern_first_line[key] = line[:120]
        except OSError:
            continue

    findings: List[Finding] = []
    for key, count in pattern_counts.items():
        findings.append(
            Finding(
                counter="tool_failure",
                pattern_key=key,
                session_id=session.session_id,
                turn_index=-1,  # substrate record, no turn index
                wasted_turns=count,
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
