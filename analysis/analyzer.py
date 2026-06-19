"""Analyzer — scan → cluster → rank orchestration."""
from __future__ import annotations

import importlib
from collections import defaultdict
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple

from analysis.config import Config
from analysis.counters import ALL_COUNTERS, Finding
from analysis.session_loader import iter_sessions


@dataclass
class Cluster:
    """Aggregated findings for one (counter, pattern_key) pair."""

    counter: str
    pattern_key: str
    wasted_turns: int
    sessions: int
    top_evidence: str


@dataclass
class Report:
    """Final ranked report."""

    clusters: List[Cluster] = field(default_factory=list)
    substrate_present: bool = False
    pi_only_sessions: int = 0
    project_label: str = ""
    since_label: str = ""


def run(config: Config) -> Report:
    """Load sessions, run counters, cluster, rank, return Report."""
    # Determine substrate presence
    substrate_present = _substrate_present(config)

    sessions = list(iter_sessions(config))

    all_findings: List[Finding] = []
    for session in sessions:
        for counter_name in ALL_COUNTERS:
            mod = importlib.import_module(f"analysis.counters.{counter_name}")
            findings = mod.run(session, config)
            all_findings.extend(findings)

    clusters = _cluster(all_findings)
    ranked = _rank(clusters)

    return Report(
        clusters=ranked,
        substrate_present=substrate_present,
        pi_only_sessions=0,
        project_label=str(config.project_dir or config.claude_projects_root),
        since_label=str(config.since),
    )


def _substrate_present(config: Config) -> bool:
    """Check if any substrate files are present."""
    try:
        from analysis.counters import hook_intervention as hi
        from analysis.counters import tool_failure as tf

        return hi.substrate_present(config) or tf.failures_present(config)
    except Exception:
        return False


def _cluster(findings: List[Finding]) -> List[Cluster]:
    """Group findings by (counter, pattern_key), aggregate wasted_turns, count sessions."""
    # key → (wasted_turns, sessions_set, top_evidence)
    groups: Dict[Tuple[str, str], List[Finding]] = defaultdict(list)
    for f in findings:
        groups[(f.counter, f.pattern_key)].append(f)

    clusters: List[Cluster] = []
    for (counter, pattern_key), fs in groups.items():
        total_wasted = sum(f.wasted_turns for f in fs)
        session_ids = {f.session_id for f in fs}
        top_evidence = fs[0].evidence if fs else ""
        clusters.append(
            Cluster(
                counter=counter,
                pattern_key=pattern_key,
                wasted_turns=total_wasted,
                sessions=len(session_ids),
                top_evidence=top_evidence,
            )
        )
    return clusters


def _rank(clusters: List[Cluster]) -> List[Cluster]:
    """Sort by wasted_turns desc, then sessions desc."""
    return sorted(clusters, key=lambda c: (-c.wasted_turns, -c.sessions))
