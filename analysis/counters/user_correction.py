"""Counter: detect user correction prompts indicating agent went wrong."""
from __future__ import annotations

import re
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.turn_window import evidence_snippet

# Correction phrases — matches indicate the agent produced wrong output
_CORRECTION_RE = re.compile(
    r"\b(no,|not what|wrong|stop|don't|do not|undo|revert|that'?s not)\b",
    re.IGNORECASE,
)

# Stronger (profanity-level frustration) phrases → weighted ×2
_STRONG_RE = re.compile(
    r"\b(wtf|damn|undo|revert)\b",
    re.IGNORECASE,
)

_HOOK_FEEDBACK_PREFIX = "Stop hook feedback:"


def run(session: Session, config: Config) -> List[Finding]:
    """Flag genuine user correction prompts (not hook feedback, not tool results)."""
    findings: List[Finding] = []

    for turn in session.turns:
        if turn.kind != "user":
            continue
        # Must be a genuine user text (not hook feedback, not tool_result list)
        if not turn.user_text:
            continue
        if turn.user_text.startswith(_HOOK_FEEDBACK_PREFIX):
            continue

        text = turn.user_text
        if _CORRECTION_RE.search(text):
            # Weight ×2 for strong/profanity phrases
            weight = 2 if _STRONG_RE.search(text) else 1
            evidence = evidence_snippet(session.turns, turn.index, config.window)
            findings.append(
                Finding(
                    counter="user_correction",
                    pattern_key="correction",
                    session_id=session.session_id,
                    turn_index=turn.index,
                    wasted_turns=weight,
                    evidence=evidence,
                )
            )

    return findings
