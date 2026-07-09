"""Counter package — one fn per waste signal, each returns list[Finding]."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import List


@dataclass
class Finding:
    """A single waste signal found in a session."""

    counter: str
    pattern_key: str
    session_id: str
    turn_index: int
    wasted_turns: int
    evidence: str


# Populated at the bottom of this file after all counter modules are defined.
# Import lazily to avoid circular-import issues.
ALL_COUNTERS: List[str] = [
    "forbidden_bash",
    "re_read",
    "hook_intervention",
    "user_correction",
    "delegation_churn",
]

# Repo-level counters run ONCE after the per-session loop (not per session).
# Their modules expose run_repo(config) -> List[Finding].
#
# hook_intervention appears in BOTH lists: its transcript leg (`run`) is
# per-session, its gate-verdicts leg (`run_repo`) is repo-level — the
# analyzer already loops both lists and calls whichever fn each exposes.
ALL_REPO_COUNTERS: List[str] = [
    "subagent_interruption",
    "tool_failure",
    "hook_intervention",
]
