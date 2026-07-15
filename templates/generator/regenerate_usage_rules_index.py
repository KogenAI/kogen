#!/usr/bin/env python3
"""regenerate_usage_rules_index.py — rebuild shared/usage_rules/INDEX.md, updating
version citations to the max version present on disk for each dep the index
ALREADY tracks.

INDEX.md is cache-scoped to the build platform's direct dependencies — it is
NOT a full listing of every dep in the shared corpus (the corpus holds docs
for many libraries used by other downstream projects too, e.g. the Ash
framework family). This script therefore never ADDS a dep to the index that
wasn't already there: it re-derives the SET OF DEPS from the existing
INDEX.md's `## <dep>` headings, then for each of those deps, re-scans the
corpus for the max version present and re-cites that version's files
(main + topic files). The hand-written "Use when: ..." prose is irreplaceable
human judgment — carried forward verbatim by dep key.

A dep heading present in INDEX.md but with ZERO matching corpus files is left
untouched (its citations preserved as-is) and reported on stderr — this is a
corpus gap, not something this script can fabricate.

Stdlib only. Deterministic: same corpus dir + same INDEX.md dep set -> same
INDEX.md bytes.

Usage:
  regenerate_usage_rules_index.py --usage-rules-dir <dir> --output <path>
  regenerate_usage_rules_index.py --usage-rules-dir <dir> --check  (diff-only, exit 1 if stale)
"""

import argparse
import re
import sys
from pathlib import Path

# Files in shared/usage_rules/ that are not per-dep docs (misc notes, corpus
# metadata) — excluded from index generation entirely.
NON_DEP_FILES = {
    "INDEX.md",
    "forms.md",
    "lifecycle.md",
    "main-index.md",
    "navigation.md",
    "uploads.md",
    "README-phoenix-1.8.8.md",
}

# Filename shape: <dep_name>-<version>[-<topic>].md
# dep_name: lowercase letters/digits/underscore, must start with a letter.
# version: starts with a digit (semver-ish, possibly with a git-<sha> shape or
# hyphenated pre-release segments) — greedy version capture handled by trying
# progressively shorter dep-name prefixes is unnecessary; we split on the
# first hyphen-digit boundary that begins a valid version token.
FILENAME_RE = re.compile(
    r"^(?P<dep>[a-z][a-z0-9_]*)-(?P<version>(?:\d[\w.]*|git-[0-9a-f]+))(?:-(?P<topic>[a-z][a-z0-9_-]*))?\.md$"
)


def version_key(version_str):
    """Sort key for version strings. Numeric semver sorts numerically;
    'git-<sha>' and other non-numeric forms sort after all numeric versions
    (treated as always-newest is wrong in general, but git-pinned deps carry
    no meaningful ordering here — corpus never carries two git shas for one
    dep in practice). Numeric parts compared as ints, not strings, so 1.8.8 >
    1.8.7 and 1.10.0 > 1.9.0."""
    if version_str.startswith("git-"):
        return (1, version_str)
    parts = re.split(r"[.\-]", version_str)
    numeric_parts = []
    for p in parts:
        if p.isdigit():
            numeric_parts.append((0, int(p)))
        else:
            numeric_parts.append((1, p))
    return (0, tuple(numeric_parts))


def scan_corpus(usage_rules_dir):
    """Returns dict: dep_name -> { version_str -> [filenames] }"""
    deps = {}
    for f in sorted(usage_rules_dir.iterdir()):
        if not f.is_file() or f.suffix != ".md":
            continue
        if f.name in NON_DEP_FILES:
            continue
        m = FILENAME_RE.match(f.name)
        if not m:
            continue
        dep = m.group("dep")
        ver = m.group("version")
        deps.setdefault(dep, {}).setdefault(ver, []).append(f.name)
    return deps


def max_version_files(versions_dict):
    """versions_dict: version_str -> [filenames]. Returns (max_version, filenames)
    for the highest version present. Caller reorders main-file-first."""
    max_version = max(versions_dict.keys(), key=version_key)
    return max_version, sorted(versions_dict[max_version])


def parse_existing_index(index_path):
    """Parse the existing INDEX.md into an ordered dict:
    dep -> {"use_when": <verbatim line or None>, "cited_files": [existing citations]}.
    Returns {} if file absent. Dep SET is derived from `## <dep>` headings —
    this is the scope this script is allowed to touch; it never adds a dep
    that wasn't already a heading here."""
    deps = {}
    if not index_path.exists():
        return deps
    text = index_path.read_text()
    current_dep = None
    for line in text.splitlines():
        h2 = re.match(r"^## (\S+)", line)
        if h2:
            current_dep = h2.group(1)
            deps[current_dep] = {"use_when": None, "cited_files": []}
            continue
        if current_dep is None:
            continue
        if line.startswith("Use when:"):
            deps[current_dep]["use_when"] = line
            continue
        cite = re.match(r"^- `([^`]+)`$", line)
        if cite:
            deps[current_dep]["cited_files"].append(cite.group(1))
    return deps


def render_index(tracked_deps, corpus_deps, orphaned_out):
    """tracked_deps: dep_name -> {"use_when": line-or-None, "cited_files": [...]}
    (the SET this script is allowed to touch — derived from the existing
    INDEX.md's headings). corpus_deps: dep_name -> {version -> [filenames]}
    (everything actually on disk). Returns INDEX.md text.

    For each tracked dep found in the corpus, cite the max version's files.
    For a tracked dep with NO corpus match, preserve its existing citations
    untouched and report it on stderr (corpus gap, not fabricatable)."""
    lines = []
    lines.append("# Usage Rules Index — Build Platform")
    lines.append("")
    lines.append(
        "This index is cache-scoped to the build platform and lists the usage-rules files"
    )
    lines.append(
        "relevant to its direct dependencies. The shared corpus contains 90+ files covering many"
    )
    lines.append(
        "more libraries; only the deps listed here are direct dependencies of the platform today."
    )
    lines.append(
        "Implementers should read only the files listed for the dep(s) relevant to their task —"
    )
    lines.append("loading the entire corpus is wasteful and token-expensive.")

    for dep in sorted(tracked_deps.keys()):
        entry = tracked_deps[dep]
        lines.append("")
        lines.append(f"## {dep}")
        lines.append("")
        if entry["use_when"] is not None:
            lines.append(entry["use_when"])
        else:
            lines.append("Use when: TODO — describe when to load this dep's usage rules.")
        lines.append("")

        if dep in corpus_deps:
            max_version, files = max_version_files(corpus_deps[dep])
            main_name = f"{dep}-{max_version}.md"
            topic_files = sorted(f for f in files if f != main_name)
            ordered_files = ([main_name] if main_name in files else []) + topic_files
        else:
            ordered_files = entry["cited_files"]
            orphaned_out.append(dep)

        for fname in ordered_files:
            lines.append(f"- `{fname}`")

    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--usage-rules-dir", required=True)
    parser.add_argument("--output")
    parser.add_argument(
        "--check",
        action="store_true",
        help="diff-only: exit 1 if regenerated INDEX.md differs from what's on disk",
    )
    args = parser.parse_args()

    usage_rules_dir = Path(args.usage_rules_dir)
    if not usage_rules_dir.is_dir():
        print(f"error: {usage_rules_dir} is not a directory", file=sys.stderr)
        return 2

    index_path = usage_rules_dir / "INDEX.md"
    tracked_deps = parse_existing_index(index_path)
    if not tracked_deps:
        print(
            f"error: {index_path} has no '## <dep>' headings to track — nothing to regenerate",
            file=sys.stderr,
        )
        return 2
    corpus_deps = scan_corpus(usage_rules_dir)

    orphaned = []
    rendered = render_index(tracked_deps, corpus_deps, orphaned)

    if orphaned:
        for dep in orphaned:
            print(
                f"regenerate_usage_rules_index: tracked dep '{dep}' has no matching corpus files — citations left unchanged (corpus gap)",
                file=sys.stderr,
            )

    if args.check:
        if not index_path.exists():
            print("regenerate_usage_rules_index: INDEX.md missing", file=sys.stderr)
            return 1
        current = index_path.read_text()
        if current.strip() != rendered.strip():
            print(
                "regenerate_usage_rules_index: shared/usage_rules/INDEX.md is STALE — "
                "does not match a fresh regeneration from the corpus on disk. "
                "Run: python3 templates/generator/regenerate_usage_rules_index.py "
                "--usage-rules-dir shared/usage_rules --output shared/usage_rules/INDEX.md",
                file=sys.stderr,
            )
            return 1
        return 0

    output_path = Path(args.output) if args.output else index_path
    output_path.write_text(rendered)
    updated = len(tracked_deps) - len(orphaned)
    print(
        f"regenerate_usage_rules_index: wrote {output_path} "
        f"({len(tracked_deps)} deps tracked, {updated} re-cited to max version, "
        f"{len(orphaned)} left unchanged)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
