"""Shared window predicate for repo-level counters.

Repo-level counters (subagent_interruption, tool_failure, hook_intervention's
gate-verdicts leg) scan flat, repo-wide substrates that are not bounded by
any single session's transcript. Each substrate carries its own date field
(cycle-log `init.stamp.at`, or a `YYYYMMDD_` filename fallback; per-record
`ts`/`started`). `in_window` is the one predicate every repo counter calls to
decide whether a given ISO-8601 timestamp falls within `--since`.

Fail-closed: a timestamp that is missing or unparseable returns False. A
windowed report must count only evidence provably inside the window —
evidence that cannot be dated is excluded, never assumed in-window.
"""
from __future__ import annotations

import datetime
from typing import Optional


def _parse_date(iso_ts: str) -> Optional[datetime.date]:
    """Parse an ISO-8601 UTC timestamp string -> date, or None if unparseable."""
    try:
        return datetime.datetime.fromisoformat(iso_ts.replace("Z", "+00:00")).date()
    except ValueError:
        return None


def in_window(iso_ts: Optional[str], since: datetime.date) -> bool:
    """Return True if `iso_ts` falls on or after `since`.

    `iso_ts` may be None or an unparseable string — both fail-closed to
    False. The boundary date (iso_ts's date == since) is INCLUDED.
    """
    if not iso_ts:
        return False
    parsed = _parse_date(iso_ts)
    if parsed is None:
        return False
    return parsed >= since
