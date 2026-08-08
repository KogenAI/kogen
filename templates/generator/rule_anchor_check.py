#!/usr/bin/env python3
"""rule_anchor_check.py — a rule that claims a mechanism must still name it.

`shared/enforcement/seam-registry.yaml` inventories declaration<->reflection
seams. A subset of those rows are RULE ANCHORS: a `declares:` entry naming a
`shared/rules/**/*.md` file, and a `reflects:` entry naming the enforcer that
backs the claim. This script is the checker for that subset only — it does
NOT duplicate seam-registry-parity_test.sh's own inventory checks (guard
resolves, guard wired, GAP rationale non-empty); those stay bash-side.

What THIS script verifies, for every seam row whose `guard:` is
`rule-anchor-check`:

    1. the rule file named in `declares:` exists on disk, and
    2. an ANCHOR TEXT for that row (registered in ANCHOR_TEXT below, one
       entry per seam id) is still present in that file, byte-exactly.

Deleting or rewording a load-bearing rule paragraph without retiring its
seam row is exactly the failure mode this exists to catch: the seam-registry
inventory would still claim the rule is anchored, but the anchor text itself
would be gone. A `guard: GAP` row is deliberately NOT covered here — GAP
rows record known-unguarded rules; they carry no ANCHOR_TEXT entry and this
script does not require one.

    --check   exit 1 (naming every missing anchor) if any registered anchor
              text is absent from its rule file. This is the CI gate.
    --report  print every registered anchor's file + a found/missing verdict,
              exit 0 regardless (diagnostic use).

Usage:
    python3 templates/generator/rule_anchor_check.py --repo-root . --check
"""

import argparse
import sys
from pathlib import Path

import yaml

SCRIPT_DIR = Path(__file__).resolve().parent
CODEGEN_DIR = SCRIPT_DIR.parent.parent
SEAM_REGISTRY = "shared/enforcement/seam-registry.yaml"
GUARD_ID = "rule-anchor-check"

# One entry per seam `id:` whose guard is GUARD_ID. The key is the seam id
# (so a mismatch between this table and the registry is itself detectable —
# see check_registry_coverage below); the value is the exact substring that
# must still appear in the rule file named by that seam's `declares:` field.
#
# These are intentionally SHORT, STABLE substrings — not whole paragraphs —
# so a rule can be reworded around the anchor without spurious failures, but
# the load-bearing SENTENCE the reflects: side depends on cannot silently
# vanish.
ANCHOR_TEXT = {
    "reviewer-verdict-sentinel-to-loop-parser": (
        "shared/rules/roles/reviewer.md",
        "REVIEW_VERDICT: APPROVED",
    ),
    "reviewer-silent-failure-scan-to-hook-disclaimer": (
        "shared/rules/roles/reviewer.md",
        "Rule S — Silent-Failure Scan",
    ),
    "reviewer-born-dead-rule-n-to-detector": (
        "shared/rules/roles/reviewer.md",
        "Rule N — No Born-Dead / Deferred Work",
    ),
    "static-visual-styling-mandate-to-render-check": (
        "shared/rules/stacks/static/developer.md",
        "## Visual Styling Mandate",
    ),
    "developer-loop-mode-gate-discipline-to-hooks": (
        "shared/rules/roles/developer.md",
        "Re-run the gate until it is GREEN",
    ),
    "developer-files-modified-typed-event-to-read-discipline": (
        "shared/rules/roles/developer.md",
        "Files Modified is ALSO a typed event",
    ),
}


class AnchorError(Exception):
    """A condition the checker cannot resolve on its own."""


def load_rule_anchor_seam_ids(repo_root: Path) -> set:
    """Seam ids in the registry whose guard is GUARD_ID."""
    registry_path = repo_root / SEAM_REGISTRY
    if not registry_path.is_file():
        raise AnchorError(f"rule-anchor-check: {SEAM_REGISTRY} not found under {repo_root}")
    data = yaml.safe_load(registry_path.read_text(encoding="utf-8"))
    seams = data.get("seams", []) if data else []
    return {s["id"] for s in seams if s.get("guard") == GUARD_ID}


def check_registry_coverage(repo_root: Path):
    """Both directions: every registered id has ANCHOR_TEXT, and vice versa."""
    registered_ids = load_rule_anchor_seam_ids(repo_root)
    table_ids = set(ANCHOR_TEXT.keys())

    missing_from_table = sorted(registered_ids - table_ids)
    missing_from_registry = sorted(table_ids - registered_ids)

    problems = []
    for seam_id in missing_from_table:
        problems.append(
            f"rule-anchor-check: seam-registry.yaml row '{seam_id}' has "
            f"guard: {GUARD_ID} but no ANCHOR_TEXT entry in "
            "rule_anchor_check.py — register the anchor text."
        )
    for seam_id in missing_from_registry:
        problems.append(
            f"rule-anchor-check: rule_anchor_check.py ANCHOR_TEXT has "
            f"'{seam_id}' but seam-registry.yaml has no matching row with "
            f"guard: {GUARD_ID} — the anchor table and the registry drifted."
        )
    return problems


def check_anchors(repo_root: Path):
    """Return list of (seam_id, relpath, anchor, found: bool) for every entry."""
    results = []
    for seam_id, (relpath, anchor) in ANCHOR_TEXT.items():
        rule_path = repo_root / relpath
        if not rule_path.is_file():
            results.append((seam_id, relpath, anchor, False))
            continue
        text = rule_path.read_text(encoding="utf-8")
        results.append((seam_id, relpath, anchor, anchor in text))
    return results


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--report", action="store_true")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()

    try:
        coverage_problems = check_registry_coverage(repo_root)
    except AnchorError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    results = check_anchors(repo_root)

    if args.report:
        for seam_id, relpath, anchor, found in results:
            verdict = "FOUND" if found else "MISSING"
            print(f"{verdict}\t{seam_id}\t{relpath}\t{anchor!r}")
        for problem in coverage_problems:
            print(problem, file=sys.stderr)
        return 0

    missing = [(seam_id, relpath, anchor) for seam_id, relpath, anchor, found in results if not found]

    if not missing and not coverage_problems:
        return 0

    for seam_id, relpath, anchor in missing:
        print(
            f"rule-anchor-check: {relpath} no longer contains the anchor "
            f"text registered for seam '{seam_id}': {anchor!r}. This rule "
            "is load-bearing — a mechanism (named in the seam row's "
            "reflects: field) depends on it. Restore the anchor, or retire "
            "the seam row with a gap_rationale explaining why the mechanism "
            "no longer needs it.",
            file=sys.stderr,
        )
    for problem in coverage_problems:
        print(problem, file=sys.stderr)

    return 1 if (missing or coverage_problems) else 0


if __name__ == "__main__":
    sys.exit(main())
