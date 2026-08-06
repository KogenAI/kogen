#!/usr/bin/env python3
"""context_index_sync.py — make the index's trigger column a DERIVED artifact.

The invariant: for every `context/<name>.md`, the file's `## Trigger Keywords`
paragraph and the "Load when prompt mentions..." cell of that file's row in
`PROJECT_CONTEXT.md` § Domain Context Files say the same thing.

That invariant used to be maintained by hand in two places, which means it
drifts — and `context-index-parity-scan.sh` then blocks every build in the
repo until a human notices which of the two copies is stale. Two hand-kept
copies of one fact is not an enforcement problem, it is a generation problem.

So: the context file is the SOURCE, the index cell is GENERATED from it.

    --check   exit 1 (and name every drifted row) if the committed index does
              not match what would be generated. This is the CI gate.
    --write   rewrite the index in place from the context files. This is the
              remedy a human/agent runs; it never needs judgement.

Only column 4 ("Load when prompt mentions...") is generated. Columns 1-3 and
5 (file, domain, update-when) stay hand-authored — nothing derives them, and
no check compares them. Rows whose column-1 is not a `context/<name>.md`
backtick reference are passed through untouched, as is every line outside the
§ Domain Context Files table.

Usage:
    python3 templates/generator/context_index_sync.py --repo-root . --check
    python3 templates/generator/context_index_sync.py --repo-root . --write
"""

import argparse
import re
import sys
from pathlib import Path

SECTION_HEADING = "## Domain Context Files"
TRIGGER_HEADING = "## Trigger Keywords"
# Zero-based index into the split cell list: 0=file, 1=domain,
# 2="Load when prompt mentions...", 3="Update when changing...".
KEYWORD_COLUMN = 2
MIN_ROW_CELLS = 4
INDEX_CANDIDATES = ("PROJECT_CONTEXT.md", "codegen/PROJECT_CONTEXT.md")

# Column 1 of a Domain Context Files row: `context/<name>.md` in backticks.
ROW_FILE_RE = re.compile(r"^`context/([a-z0-9_-]+\.md)`$")


class SyncError(Exception):
    """A condition the generator cannot resolve on its own."""


def resolve_index_path(repo_root: Path) -> Path:
    for candidate in INDEX_CANDIDATES:
        path = repo_root / candidate
        if path.is_file():
            return path
    raise SyncError(
        "context-index-sync: no index doc found (looked for "
        + ", ".join(INDEX_CANDIDATES)
        + f" under {repo_root})"
    )


def read_trigger_keywords(context_file: Path) -> str:
    """First non-blank line of the file's `## Trigger Keywords` section.

    Returns the raw line, stripped of surrounding whitespace only — the index
    cell is a byte-for-byte copy of it, so any markdown escaping (`\\_build`)
    or backticks in the source carry through unchanged.
    """
    lines = context_file.read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines):
        if line.rstrip() != TRIGGER_HEADING:
            continue
        for body in lines[i + 1 :]:
            if body.strip() == "":
                continue
            if body.startswith("#"):
                break  # section is empty — next heading reached first
            return body.strip()
        break
    raise SyncError(
        f"context-index-sync: {context_file.name} has no non-empty "
        f"'{TRIGGER_HEADING}' section — add one; the index row is generated "
        "from it."
    )


def split_row(line: str):
    """Split a markdown table row into its cells.

    Returns None when `line` is not a table row. A row is `| a | b | ... |`;
    stripping the leading and trailing pipe before splitting keeps empty
    leading/trailing artifacts out of the cell list.
    """
    stripped = line.strip()
    if not stripped.startswith("|"):
        return None
    body = stripped[1:]
    if body.endswith("|"):
        body = body[:-1]
    return body.split("|")


def is_separator_row(cells) -> bool:
    return all(set(cell.strip()) <= set("-: ") and cell.strip() for cell in cells)


def render_row(cells) -> str:
    return "|" + "|".join(cells) + "|"


def generate(repo_root: Path):
    """Return (index_path, original_text, generated_text, drifted_basenames)."""
    index_path = resolve_index_path(repo_root)
    original = index_path.read_text(encoding="utf-8")
    lines = original.split("\n")

    in_section = False
    out = []
    drifted = []

    for line in lines:
        if line.startswith("## "):
            in_section = line.rstrip() == SECTION_HEADING
            out.append(line)
            continue

        cells = split_row(line) if in_section else None
        if not cells or is_separator_row(cells):
            out.append(line)
            continue

        match = ROW_FILE_RE.match(cells[0].strip())
        if not match:
            out.append(line)
            continue

        basename = match.group(1)
        if len(cells) < MIN_ROW_CELLS:
            raise SyncError(
                f"context-index-sync: {index_path.name} § Domain Context "
                f"Files row for context/{basename} has {len(cells)} "
                f"column(s), expected at least {MIN_ROW_CELLS} "
                "(file | domain | load-when | update-when)."
            )
        context_file = repo_root / "context" / basename
        if not context_file.is_file():
            raise SyncError(
                f"context-index-sync: {index_path.name} has a row for "
                f"context/{basename} but that file does not exist. Add the "
                "file or remove the row (the generator will not guess)."
            )

        keywords = read_trigger_keywords(context_file)
        expected = f" {keywords} "
        if cells[KEYWORD_COLUMN] != expected:
            drifted.append(basename)
            cells[KEYWORD_COLUMN] = expected
        out.append(render_row(cells))

    return index_path, original, "\n".join(out), drifted


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", default=".")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args(argv)

    repo_root = Path(args.repo_root).resolve()

    try:
        index_path, original, generated, drifted = generate(repo_root)
    except SyncError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    rel = index_path.relative_to(repo_root)

    if args.write:
        if generated == original:
            print(f"context-index-sync: {rel} already in sync")
            return 0
        index_path.write_text(generated, encoding="utf-8")
        print(
            f"context-index-sync: regenerated {len(drifted)} row(s) in {rel}: "
            + ", ".join(drifted)
        )
        return 0

    if generated == original:
        return 0

    for basename in drifted:
        print(
            f"context-index-sync: {rel} § Domain Context Files row for "
            f"context/{basename} does not match context/{basename} "
            f"§ Trigger Keywords.",
            file=sys.stderr,
        )
    print(
        "context-index-sync: the index trigger column is GENERATED from the "
        "context files. Edit context/<name>.md § Trigger Keywords, then run "
        "`make context-index-sync`.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main())
