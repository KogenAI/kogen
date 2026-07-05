"""select.py — deterministic, pure selection of turn-waste clusters to propose.

No LLM calls, no side effects beyond stdin read / stdout write in __main__.
Consumes JSONL cluster records (as emitted by `codegen-analyze --json` /
analysis.report_writer._render_json) and returns a ranked, capped subset.
"""
from __future__ import annotations

import argparse
import json
import sys
from typing import Dict, List

from analysis.proposer import (
    COUNTER_CONFIDENCE_PRIOR,
    DEFAULT_MAX_PROPOSALS,
    DEFAULT_MIN_WASTED_TURNS,
    DROP_COUNTERS,
)

_PRIOR_RANK: Dict[str, int] = {"high": 3, "medium": 2, "low": 1}


def _weight(cluster: dict) -> int:
    prior = COUNTER_CONFIDENCE_PRIOR.get(cluster["counter"], "low")
    return _PRIOR_RANK[prior] * cluster["wasted_turns"]


def select_clusters(
    clusters: List[dict],
    *,
    min_wasted_turns: int = DEFAULT_MIN_WASTED_TURNS,
    max_proposals: int = DEFAULT_MAX_PROPOSALS,
) -> List[dict]:
    """Filter + rank clusters, return top max_proposals.

    Drops: clusters whose counter is in DROP_COUNTERS; clusters with
    wasted_turns < min_wasted_turns.
    Sort: descending by weight = prior_rank(counter) * wasted_turns, tie-break
    by wasted_turns descending, then pattern_key ascending (deterministic).
    """
    eligible = [
        c
        for c in clusters
        if c["counter"] not in DROP_COUNTERS and c["wasted_turns"] >= min_wasted_turns
    ]
    eligible.sort(
        key=lambda c: (-_weight(c), -c["wasted_turns"], c["pattern_key"])
    )
    return eligible[:max_proposals]


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="analysis.proposer.select",
        description=(
            "Read JSONL turn-waste clusters on stdin, emit the top-ranked "
            "selection as JSONL on stdout."
        ),
    )
    parser.add_argument(
        "--min-wasted-turns",
        type=int,
        default=DEFAULT_MIN_WASTED_TURNS,
        dest="min_wasted_turns",
    )
    parser.add_argument(
        "--max",
        type=int,
        default=DEFAULT_MAX_PROPOSALS,
        dest="max_proposals",
    )
    args = parser.parse_args()

    clusters = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        # Fail loud on malformed JSON — a broken analyzer line must surface,
        # never be silently skipped.
        clusters.append(json.loads(line))

    selected = select_clusters(
        clusters,
        min_wasted_turns=args.min_wasted_turns,
        max_proposals=args.max_proposals,
    )
    for c in selected:
        print(json.dumps(c))


if __name__ == "__main__":
    main()
