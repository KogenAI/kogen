"""Proposer package — turns ranked turn-waste clusters into proposed-change records.

Pure/deterministic selection lives in select.py (no LLM, no side effects).
The LLM-driven per-cluster expansion into a full proposed-change record is
done by the codegen-propose bash launcher (one codegen-call per cluster),
NOT by this package.
"""
from __future__ import annotations

from typing import Dict

# Confidence prior per counter — how reliable is this signal at pointing to
# a real, actionable fix (vs. noise/infra flakiness).
COUNTER_CONFIDENCE_PRIOR: Dict[str, str] = {
    "forbidden_bash": "high",
    "user_correction": "high",
    "context_missed": "high",
    "re_read": "medium",
    "delegation_churn": "medium",
    "hook_intervention": "medium",
    "tool_failure": "medium",
    "subagent_interruption": "low",
}

# Playbook: which class of target file/fix a given counter's waste pattern
# maps to. Carried into the per-cluster LLM prompt so the model knows where
# to look for the fix.
COUNTER_FIX_TYPE: Dict[str, str] = {
    "forbidden_bash": (
        "prompt-coverage edit (name the forbidden guard in launcher prompt); "
        "target harnesses/*/tools-header/*.txt, prompt-bodies/*.txt"
    ),
    "user_correction": "rule clarification; target shared/rules/**",
    "re_read": "context structure/caching change; target context/*.md, PROJECT_CONTEXT.md",
    "context_missed": "context structure change; target context/*.md, PROJECT_CONTEXT.md",
    "delegation_churn": "orchestration/routing prompt fix; target orchestrator prompt/role routing",
    "hook_intervention": (
        "guard-tuning or prompt fix; target shared/enforcement/registry.yaml "
        "or launcher prompt"
    ),
    "tool_failure": "tool-usage guidance; target role prompt bodies",
    "subagent_interruption": (
        "robustness note (often infra, low confidence, may not propose); "
        "flagged, usually filtered"
    ),
}

DEFAULT_MIN_WASTED_TURNS = 4
DEFAULT_MAX_PROPOSALS = 5

# Counters dropped by default — infra/low-confidence signals that rarely
# point at an actionable, groundable fix.
DROP_COUNTERS = frozenset({"subagent_interruption"})

# Numeric rank per confidence prior — used to weight clusters so high-trust
# counters outrank low-trust counters even at lower raw wasted_turns.
_PRIOR_RANK: Dict[str, int] = {"high": 3, "medium": 2, "low": 1}


def weight(counter: str, wasted_turns: int) -> int:
    """Trust-weighted score for a cluster: prior_rank(counter) * wasted_turns.

    Shared by analysis.proposer.select (machine selection) and
    analysis.report_writer (human table default ranking) — single source
    of truth for "what does the proposer trust".
    """
    prior = COUNTER_CONFIDENCE_PRIOR.get(counter, "low")
    return _PRIOR_RANK[prior] * wasted_turns
