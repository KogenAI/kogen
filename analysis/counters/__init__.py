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
    "tool_failure",
]
