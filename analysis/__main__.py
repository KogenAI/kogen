"""Entry point for `python3 -m analysis` — argparse front-end."""
from __future__ import annotations

import argparse
import datetime
import sys
from pathlib import Path


def _parse_date(value: str) -> datetime.date:
    try:
        return datetime.date.fromisoformat(value)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"Invalid date '{value}': expected YYYY-MM-DD format"
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="codegen-analyze",
        description=(
            "Scan existing Claude sessions for agent turn-waste and print a ranked report."
        ),
    )
    parser.add_argument(
        "--since",
        metavar="YYYY-MM-DD",
        type=_parse_date,
        default=datetime.date.today() - datetime.timedelta(days=14),
        help="Include sessions on or after this date (default: today − 14 days)",
    )
    parser.add_argument(
        "--json",
        action="store_true",
        dest="as_json",
        help="Emit one JSON object per cluster (machine-readable)",
    )
    parser.add_argument(
        "--window",
        metavar="N",
        type=int,
        default=2,
        help="Evidence window radius around each flagged turn (default: 2)",
    )
    parser.add_argument(
        "--threshold-reread",
        metavar="N",
        type=int,
        default=2,
        dest="reread_threshold",
        help="Flag files read more than N times per session (default: 2)",
    )
    parser.add_argument(
        "--raw",
        action="store_true",
        dest="raw",
        help=(
            "Show raw wasted_turns-desc table incl. dropped counters "
            "(default: proposer-weighted, dropped hidden)"
        ),
    )
    parser.add_argument(
        "--project-dir",
        metavar="DIR",
        type=Path,
        default=None,
        dest="project_dir",
        help=(
            "Load *.jsonl directly from DIR (overrides Claude projects glob; "
            "used for hermetic testing)"
        ),
    )

    args = parser.parse_args()

    from analysis.config import Config
    from analysis.analyzer import run
    from analysis.report_writer import render_report

    config = Config(
        since=args.since,
        as_json=args.as_json,
        window=args.window,
        reread_threshold=args.reread_threshold,
        project_dir=args.project_dir,
    )

    report = run(config)
    output = render_report(report, as_json=args.as_json, raw=args.raw)
    print(output)


if __name__ == "__main__":
    main()
