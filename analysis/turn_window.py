"""Evidence window — slice ±radius turns around a flagged index."""
from __future__ import annotations

from typing import List, TYPE_CHECKING

if TYPE_CHECKING:
    from analysis.session_loader import Turn


def window(turns: "List[Turn]", idx: int, radius: int) -> "List[Turn]":
    """Return turns[max(0, idx-radius) : idx+radius+1] — clamped to bounds."""
    start = max(0, idx - radius)
    end = min(len(turns), idx + radius + 1)
    return turns[start:end]


def evidence_snippet(turns: "List[Turn]", idx: int, radius: int) -> str:
    """Produce a short text summary of the evidence window around idx."""
    slc = window(turns, idx, radius)
    parts = []
    for turn in slc:
        marker = "→" if turn.index == idx else " "
        if turn.tool_uses:
            names = ", ".join(
                f"{tu.name}({tu.command or tu.file_path or tu.description or ''})"
                for tu in turn.tool_uses
            )
            parts.append(f"{marker}[{turn.index}] {turn.kind}: {names}")
        elif turn.user_text:
            snippet = turn.user_text[:80].replace("\n", " ")
            parts.append(f"{marker}[{turn.index}] user: {snippet}")
        elif turn.tool_results:
            err = any(r.is_error for r in turn.tool_results)
            parts.append(f"{marker}[{turn.index}] result: {'ERROR' if err else 'ok'}")
        else:
            parts.append(f"{marker}[{turn.index}] {turn.kind}")
    return "; ".join(parts)
