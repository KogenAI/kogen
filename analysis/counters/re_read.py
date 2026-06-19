"""Counter: detect files read more than config.reread_threshold times in one session."""
from __future__ import annotations

from collections import Counter
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.turn_window import evidence_snippet


def run(session: Session, config: Config) -> List[Finding]:
    """Flag files read > reread_threshold times within a session."""
    read_counts: Counter[str] = Counter()
    # Track first turn index per file for evidence anchoring
    first_index: dict = {}

    for turn in session.turns:
        for tu in turn.tool_uses:
            if tu.name == "Read" and tu.file_path:
                path = tu.file_path
                read_counts[path] += 1
                if path not in first_index:
                    first_index[path] = turn.index

    findings: List[Finding] = []
    for path, count in read_counts.items():
        if count > config.reread_threshold:
            idx = first_index[path]
            extra_reads = count - config.reread_threshold
            evidence = evidence_snippet(session.turns, idx, config.window)
            findings.append(
                Finding(
                    counter="re_read",
                    pattern_key=path,
                    session_id=session.session_id,
                    turn_index=idx,
                    wasted_turns=extra_reads,
                    evidence=evidence,
                )
            )
    return findings
