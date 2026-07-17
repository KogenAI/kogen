#!/usr/bin/env python3
"""prompt_size_budget.py — fail-closed size-budget gate for the prompt
attention surface: rendered agent system prompts + shared/role/stack rule
files.

Two checks, both against a single committed baseline file
(templates/generator/prompt-budgets.txt):

1. Rendered agent prompts (shared/subagents/{shared,phoenix,static}/*.md.j2,
   rendered via process_template.py for the `claude` harness with YAML
   frontmatter) — byte size must not exceed its committed budget.
2. Rule files under shared/rules/_core/, shared/rules/roles/, and
   shared/rules/stacks/**/ — line count must not exceed its committed budget.

The baseline is NOT the STYLE_GUIDE.md target (_core < 50 lines, roles/stacks
< 150 lines) — several rule files already exceed those targets today (scar
tissue, not new debt). This gate freezes CURRENT size as a ceiling so growth
never happens silently. A file at or under the STYLE_GUIDE target already
satisfies both the target and any committed budget.

prompt-budgets.txt is OPERATOR-OWNED: an over-budget file must be shrunk or
evicted-from, never raised, by any agent role. --write is a terminal-only
operator command; every agent write path to prompt-budgets.txt (Edit/Write/
MultiEdit, the --write flag, Bash write-vocab) is denied by the
prompt-budget-writer-only hook.

Stdlib only. Deterministic: same repo tree -> same verdict.

Usage:
  prompt_size_budget.py --check                 (default: fails loud on any
                                                   overage or missing budget row)
  prompt_size_budget.py --write                  (operator-only, terminal:
                                                   regenerate prompt-budgets.txt
                                                   from CURRENT measured sizes)
"""

import argparse
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CODEGEN_DIR = SCRIPT_DIR.parent.parent
BUDGET_FILE = SCRIPT_DIR / "prompt-budgets.txt"

REMEDY_MESSAGE = (
    "This file is FULL. The budget is not yours to raise — it is operator-owned.\n"
    "Fix, in order:\n"
    "  1. Shrink your addition to fit the space that is left.\n"
    "  2. If it cannot fit: evict the lowest-value content in this file and NAME what\n"
    "     you evicted in your diff. Never delete a load-bearing fact — compress prose,\n"
    "     merge examples, or relocate a worked-example to context/*.md first.\n"
    "Do not edit prompt-budgets.txt and do not attempt to raise its ceiling — every "
    "agent write path to that file is denied."
)

RULE_DIRS = [
    CODEGEN_DIR / "shared" / "rules" / "_core",
    CODEGEN_DIR / "shared" / "rules" / "roles",
    CODEGEN_DIR / "shared" / "rules" / "stacks",
]

AGENT_SUBAGENT_DIRS = [
    CODEGEN_DIR / "shared" / "subagents" / "shared",
    CODEGEN_DIR / "shared" / "subagents" / "phoenix",
    CODEGEN_DIR / "shared" / "subagents" / "static",
]


def measure_rule_files():
    """Returns dict: relpath (str, POSIX, relative to CODEGEN_DIR) -> line count."""
    sizes = {}
    for rule_dir in RULE_DIRS:
        if not rule_dir.is_dir():
            continue
        for f in sorted(rule_dir.rglob("*.md")):
            relpath = f.relative_to(CODEGEN_DIR).as_posix()
            sizes[relpath] = len(f.read_text().splitlines())
    return sizes


def measure_agent_prompts():
    """Renders each shared/subagents/**/*.md.j2 for the claude harness (same
    invocation shape as generate.sh's claude subagent loop) and returns dict:
    relpath (str, POSIX, relative to CODEGEN_DIR, of the .j2 source) -> byte size
    of the rendered output."""
    sizes = {}
    for subdir in AGENT_SUBAGENT_DIRS:
        if not subdir.is_dir():
            continue
        for f in sorted(subdir.glob("*.md.j2")):
            relpath = f.relative_to(CODEGEN_DIR).as_posix()
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT_DIR / "process_template.py"),
                    "--config",
                    str(SCRIPT_DIR / "config.yaml"),
                    str(f),
                    "claude",
                    "true",
                ],
                cwd=str(CODEGEN_DIR),
                env={"CODEGEN_DIR": str(CODEGEN_DIR), "PATH": "/usr/bin:/bin:/usr/local/bin"},
                capture_output=True,
                text=True,
                check=True,
            )
            sizes[relpath] = len(result.stdout.encode("utf-8"))
    return sizes


def parse_budget_file(path):
    """Format: one row per line, `<relpath> <max>` (space-separated, relpath
    has no spaces). Blank lines and lines starting with # are skipped.
    Returns dict: relpath -> max (int)."""
    budgets = {}
    if not path.exists():
        return budgets
    for line in path.read_text().splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        parts = stripped.rsplit(" ", 1)
        if len(parts) != 2:
            print(f"prompt_size_budget: malformed budget row: {line!r}", file=sys.stderr)
            continue
        relpath, max_str = parts
        try:
            budgets[relpath] = int(max_str)
        except ValueError:
            print(f"prompt_size_budget: malformed budget row: {line!r}", file=sys.stderr)
    return budgets


def render_budget_file(rule_sizes, agent_sizes):
    lines = []
    lines.append("# prompt-budgets.txt — committed size ceilings for the prompt attention")
    lines.append("# surface. This file is OPERATOR-OWNED. It has exactly one legitimate")
    lines.append("# writer: an operator running the command below from a terminal. Every")
    lines.append("# agent write path (Edit/Write/MultiEdit, the --write flag, Bash write-vocab)")
    lines.append("# is denied by prompt-budget-writer-only — see harnesses/claude/hooks/.")
    lines.append("# Regenerate: python3 templates/generator/prompt_size_budget.py --write")
    lines.append("#")
    lines.append("# Rule files: line count. Rendered agent prompts: byte count.")
    lines.append("# A capped file that overflows must shrink or evict — the cap is not the")
    lines.append("# writer's to move.")
    lines.append("")
    lines.append("# --- rule files (line count) ---")
    for relpath in sorted(rule_sizes):
        lines.append(f"{relpath} {rule_sizes[relpath]}")
    lines.append("")
    lines.append("# --- rendered agent prompts (byte count) ---")
    for relpath in sorted(agent_sizes):
        lines.append(f"{relpath} {agent_sizes[relpath]}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail loud (exit 1) if any measured file exceeds its committed budget, "
        "or has no budget row at all",
    )
    parser.add_argument(
        "--write",
        action="store_true",
        help="regenerate prompt-budgets.txt from current measured sizes",
    )
    args = parser.parse_args()

    if not args.check and not args.write:
        args.check = True  # default action

    rule_sizes = measure_rule_files()
    agent_sizes = measure_agent_prompts()

    if args.write:
        rendered = render_budget_file(rule_sizes, agent_sizes)
        BUDGET_FILE.write_text(rendered)
        print(f"prompt_size_budget: wrote {BUDGET_FILE} ({len(rule_sizes)} rule files, {len(agent_sizes)} agent prompts)")
        return 0

    budgets = parse_budget_file(BUDGET_FILE)
    if not budgets:
        print(
            f"prompt_size_budget: {BUDGET_FILE} missing or empty — run with --write to seed it",
            file=sys.stderr,
        )
        return 1

    failures = []
    all_sizes = {}
    all_sizes.update(rule_sizes)
    all_sizes.update(agent_sizes)

    for relpath, actual in sorted(all_sizes.items()):
        if relpath not in budgets:
            failures.append(f"{relpath}: no committed budget row — run --write to seed one")
            continue
        budget = budgets[relpath]
        if actual > budget:
            unit = "bytes" if relpath in agent_sizes else "lines"
            failures.append(f"{relpath}: {actual} {unit} exceeds committed budget {budget} {unit}")

    # A budget row naming a file that no longer exists is stale — flag it too,
    # so a deleted/renamed file doesn't leave an orphaned ceiling forever.
    for relpath in sorted(budgets):
        if relpath not in all_sizes:
            failures.append(f"{relpath}: budget row present but file no longer exists — stale row")

    if failures:
        print("prompt_size_budget: FAILED — prompt attention budget exceeded:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print(REMEDY_MESSAGE, file=sys.stderr)
        return 1

    print(f"prompt_size_budget: OK — {len(all_sizes)} files within committed budget")
    return 0


if __name__ == "__main__":
    sys.exit(main())
