"""Counter: detect context-selection misses — a role denied a context/*.md read.

The signal is already durable: subagent-read-discipline.sh's deny text lands
in the transcript as a tool_result with is_error=true, naming the file the
agent wanted. Nothing mined it until now.

Match discipline (probed, load-bearing):
  - Read tool_results[].content, NOT user_text. hook_intervention's `run` leg
    reads user_text; copying that shape here finds ZERO denies (the deny
    text is a tool_result, never a user turn).
  - Require is_error is True AND anchor the regex at string start. An
    unanchored scan matches the hook's own SOURCE (the FILE_PATH variable
    literal), regex literals in docs, and prior probe output — roughly
    two-thirds of raw hits are self-reference, not real denies.
  - Match only the stable prefix ("... cannot read <path> for orientation.").
    The remediation sentence that follows has two historical wordings
    (older: "planner's ## Files to touch ..."; current: "planner's
    files_to_touch event"); anchoring on it would silently drop every
    historical deny and defeat the retroactive benefit of mining this signal.
"""
from __future__ import annotations

import re
from typing import List

from analysis.config import Config
from analysis.counters import Finding
from analysis.session_loader import Session
from analysis.turn_window import evidence_snippet

# Anchored at string start; captures the wanted path. Tolerates an "Error: "
# prefix some harness result shapes prepend.
_DENY_RE = re.compile(
    r"^(?:Error:\s*)?(?:Developer|Reviewer|Committer) cannot read (\S+) for orientation\."
)


def _normalize(path: str) -> str:
    """Absolute -> repo-relative. Live denies carry both forms."""
    idx = path.find("context/")
    if idx != -1:
        return path[idx:]
    return path


def run(session: Session, config: Config) -> List[Finding]:
    """Find context-selection misses from denied Read tool results."""
    findings: List[Finding] = []

    for turn in session.turns:
        for result in turn.tool_results:
            if result.is_error is not True:
                continue
            match = _DENY_RE.match(result.content.strip())
            if match is None:
                continue
            findings.append(
                Finding(
                    counter="context_missed",
                    pattern_key=_normalize(match.group(1)),
                    session_id=session.session_id,
                    turn_index=turn.index,
                    wasted_turns=1,
                    evidence=evidence_snippet(session.turns, turn.index, config.window),
                )
            )

    return findings
