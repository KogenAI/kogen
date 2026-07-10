"""Report writer — human table and --json output."""
from __future__ import annotations

import json
from typing import List, TYPE_CHECKING

if TYPE_CHECKING:
    from analysis.analyzer import Cluster, Report


def render(report: "Report") -> str:
    """Render a Report to a string (human table or JSON depending on as_json param).

    This fn is called by __main__.py which passes the config.as_json flag
    separately via render_report().
    """
    raise NotImplementedError("Use render_report(report, as_json) instead.")


def render_report(report: "Report", as_json: bool = False, raw: bool = False) -> str:
    """Render a Report to a string.

    as_json=True → one JSON object per cluster (machine-readable); raw is a
    no-op in this path (JSON contract is unfiltered/unordered by this fn).
    as_json=False → fixed-width human table.
      raw=False (default) → ranked by the proposer trust model (prior-
        weighted) with DROP_COUNTERS hidden — matches what codegen-propose
        would select.
      raw=True → today's raw wasted_turns-desc order, DROP_COUNTERS included.
    """
    clusters = report.clusters

    if not clusters:
        return (
            f"no sessions found for {report.project_label} since {report.since_label}"
        )

    if as_json:
        return _render_json(clusters)

    return _render_table(report, clusters, raw=raw)


def _render_json(clusters: "List[Cluster]") -> str:
    lines = []
    for c in clusters:
        lines.append(
            json.dumps(
                {
                    "counter": c.counter,
                    "pattern_key": c.pattern_key,
                    "wasted_turns": c.wasted_turns,
                    "sessions": c.sessions,
                    "top_evidence": c.top_evidence,
                }
            )
        )
    return "\n".join(lines)


def _render_table(report: "Report", clusters: "List[Cluster]", raw: bool = False) -> str:
    header_lines = []
    if not report.substrate_present:
        header_lines.append(
            "substrate not found — tool-failure + gate-verdict signals omitted"
        )
    header_lines.append(
        f"project: {report.project_label}  since: {report.since_label}"
    )

    if raw:
        display_clusters = clusters
    else:
        from analysis.proposer import DROP_COUNTERS, weight

        display_clusters = [c for c in clusters if c.counter not in DROP_COUNTERS]
        if not display_clusters:
            header_str = "\n".join(header_lines)
            return (
                f"{header_str}\n\n"
                "all clusters below proposer-drop threshold — rerun with --raw"
            )
        display_clusters = sorted(
            display_clusters,
            key=lambda c: (-weight(c.counter, c.wasted_turns), -c.wasted_turns, c.pattern_key),
        )

    clusters = display_clusters

    col_pattern = max(len("PATTERN"), max(len(c.pattern_key) for c in clusters))
    col_counter = max(len("COUNTER"), max(len(c.counter) for c in clusters))
    col_sessions = max(len("SESSIONS"), max(len(str(c.sessions)) for c in clusters))
    col_turns = max(
        len("TURNS_WASTED"), max(len(str(c.wasted_turns)) for c in clusters)
    )

    sep = (
        f"{'─' * col_pattern}-+-{'─' * col_counter}-+-"
        f"{'─' * col_sessions}-+-{'─' * col_turns}-+-{'─' * 40}"
    )

    header_row = (
        f"{'PATTERN':<{col_pattern}} | {'COUNTER':<{col_counter}} | "
        f"{'SESSIONS':<{col_sessions}} | {'TURNS_WASTED':<{col_turns}} | TOP_EVIDENCE"
    )

    rows = [header_row, sep]
    for c in clusters:
        evidence_short = c.top_evidence[:60].replace("\n", " ")
        rows.append(
            f"{c.pattern_key:<{col_pattern}} | {c.counter:<{col_counter}} | "
            f"{c.sessions:<{col_sessions}} | {c.wasted_turns:<{col_turns}} | {evidence_short}"
        )

    table = "\n".join(rows)
    header_str = "\n".join(header_lines)
    return f"{header_str}\n\n{table}"
