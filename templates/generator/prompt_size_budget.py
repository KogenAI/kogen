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
  prompt_size_budget.py --report [--path <repo-relative>] [--added-bytes <n>]
                                                  (read-only; see below)

--report is a READ-ONLY reach projector, in two forms:

  --report --path <p> [--added-bytes <n>] — the targeted question an editor
    or the rule-edit-reach.sh hook asks before/at edit time: <p>'s own
    committed line budget + headroom, which rendered prompts it reaches
    (fan-out via the SAME transitive {% include %} walk process_template.py
    performs), each reached prompt's current headroom, and — with
    --added-bytes — which prompts would overflow, by how much, and the total
    that must be evicted this pass to fit. This form supersedes
    context-curator-guard.sh's old (deleted) warn_if_over_cap: it carries the
    same own-row line projection PLUS the fan-out projection that helper
    never had.

  --report (no --path) — the whole-corpus meter: every rendered prompt as
    now/budget/headroom, every rule fragment as fan-out -> tightest
    downstream headroom. KEEP-ADVISORY: this form has no automated caller
    and none is planned — it exists for a human operator reading the corpus,
    the same "no consumer, kept anyway" shape as codegen-analyze/
    codegen-propose. Do not wire an automated caller to the bare form; add
    --path instead, which IS the wired, consumed shape (rule-edit-reach.sh).
"""

import argparse
import re
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

# Ceiling applied to a rule file that has NO committed row — derived from the
# STYLE_GUIDE.md targets (shared rules < 50 lines, subagent/orchestration rules
# < 150 lines) rather than from a row someone has to remember to add.
#
# Why derive instead of failing: the committed rows freeze CURRENT size as a
# grandfathered ceiling for files that predate the gate. A brand-new rule file
# has no such history, so "no row" used to be a hard fail whose ONLY stated
# remedy was `--write` — a command every agent write path to this file denies.
# That is a deadlock: the role that legitimately adds a rule file (curator,
# /rule) could not clear the gate by any action available to it. Deriving the
# ceiling removes the deadlock WITHOUT loosening anything: a new file is held
# to the STYLE_GUIDE target, which is STRICTER than the grandfathered ceilings
# beside it, and an overflow has an action the author can actually take —
# shrink it.
DERIVED_CEILING_LINES = {
    "shared/rules/_core": 50,
    "shared/rules/roles": 150,
    "shared/rules/stacks": 150,
}
DERIVED_CEILING_FALLBACK_LINES = 150


def derived_ceiling(relpath):
    """STYLE_GUIDE-derived line ceiling for a rule file with no committed row."""
    for prefix, ceiling in DERIVED_CEILING_LINES.items():
        if relpath.startswith(prefix + "/"):
            return ceiling
    return DERIVED_CEILING_FALLBACK_LINES


def effective_ceiling(relpath, current, budgets):
    """One-way ratchet: once a rule file reaches its STYLE_GUIDE-derived
    target, hold it there forever — never let a shrunk file silently regrow
    back up to its grandfathered committed row.

    A committed row is a grandfathered ceiling (operator-owned, never lowered
    by an agent) — a file that shrinks from 225 to 48 lines still has 177
    lines of headroom until an operator re-runs --write. This binds ONLY when
    the file is already AT OR UNDER its derived ceiling: a file still over
    target keeps its grandfathered row untouched (nothing green today turns
    red). Agent prompts (no derivable ceiling) are untouched by this — only
    rule fragments under shared/rules/ have a derived_ceiling.
    """
    committed = budgets.get(relpath)
    if committed is None:
        return derived_ceiling(relpath)
    target = derived_ceiling(relpath)
    if current <= target:
        return min(committed, target)
    return committed

AGENT_SUBAGENT_DIRS = [
    CODEGEN_DIR / "shared" / "subagents" / "shared",
    CODEGEN_DIR / "shared" / "subagents" / "phoenix",
    CODEGEN_DIR / "shared" / "subagents" / "static",
]

# Same {% include '<path>' %} regex process_template.py's resolve_include /
# process_includes_recursively pair uses — a literal quoted path only (no
# variables, no conditionals), so the transitive walk below is exact, not a
# heuristic.
INCLUDE_RE = re.compile(r"\{%\s*include\s+['\"]([^'\"]+)['\"]\s*%\}")


def _all_top_level_prompts():
    """Every shared/subagents/{shared,phoenix,static}/*.md.j2 top-level
    prompt template, relative to CODEGEN_DIR (POSIX), sorted."""
    prompts = []
    for subdir in AGENT_SUBAGENT_DIRS:
        if not subdir.is_dir():
            continue
        for f in sorted(subdir.glob("*.md.j2")):
            prompts.append(f.relative_to(CODEGEN_DIR).as_posix())
    return prompts


def _includes_of(template_relpath):
    """Direct {% include %} targets of one template, resolved to CODEGEN_DIR-
    relative POSIX paths (rules/... -> shared/rules/...). Occurrence-counted:
    a template that includes the same fragment twice yields it twice."""
    full = CODEGEN_DIR / template_relpath
    if not full.is_file():
        return []
    content = full.read_text()
    targets = []
    for m in INCLUDE_RE.finditer(content):
        include_path = m.group(1).strip()
        resolved = (CODEGEN_DIR / "shared" / include_path).resolve()
        try:
            rel = resolved.relative_to(CODEGEN_DIR.resolve()).as_posix()
        except ValueError:
            # Outside CODEGEN_DIR entirely — not expected, but do not crash
            # the walk over it; just record the resolved absolute form.
            rel = str(resolved)
        targets.append(rel)
    return targets


def build_include_graph():
    """Transitive {% include %} walk over every top-level prompt template.

    Returns (fanout, reach):
      fanout: dict relpath (rule/subagent fragment, CODEGEN_DIR-relative
              POSIX) -> sorted list of top-level prompt relpaths that reach
              it transitively (occurrence-deduped per prompt: a prompt that
              reaches a fragment via two different paths counts once in this
              list — REACH is a prompt-level fact, not an occurrence count).
      reach: dict top-level prompt relpath -> sorted list of every fragment
             relpath it transitively includes (deduped the same way).

    MAX_DEPTH mirrors process_template.py's own recursion cap (10) so a
    pathological include cycle cannot spin this walk forever; in practice
    the real include graph is a shallow DAG (2-3 levels).
    """
    MAX_DEPTH = 10
    fanout = {}
    reach = {}
    for prompt in _all_top_level_prompts():
        seen = set()
        frontier = [prompt]
        depth = 0
        while frontier and depth < MAX_DEPTH:
            next_frontier = []
            for node in frontier:
                for target in _includes_of(node):
                    if target not in seen:
                        seen.add(target)
                        next_frontier.append(target)
            frontier = next_frontier
            depth += 1
        reach[prompt] = sorted(seen)
        for fragment in seen:
            fanout.setdefault(fragment, set()).add(prompt)
    fanout = {k: sorted(v) for k, v in sorted(fanout.items())}
    return fanout, reach


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


def attribute_prompt_overage(prompt_relpath, reach, rule_sizes, top_n=3):
    """Human-readable attribution line for an overflowing rendered prompt:
    the top_n heaviest rule fragments it transitively includes, by CURRENT
    line count. This is current-contribution attribution, not a diff against
    a prior render — enough to aim an eviction, no git-history dependency.

    Returns "" when the prompt has no rule-fragment reach recorded (reach is
    keyed by build_include_graph(), which always has an entry for every
    top-level prompt scanned — an empty return only happens if the prompt
    relpath itself was never walked)."""
    fragments = reach.get(prompt_relpath, [])
    sized = [(f, rule_sizes[f]) for f in fragments if f in rule_sizes]
    if not sized:
        return ""
    sized.sort(key=lambda pair: pair[1], reverse=True)
    top = sized[:top_n]
    parts = ", ".join(f"{relpath} ({lines} lines)" for relpath, lines in top)
    return f" Heaviest included fragments: {parts}. Run --report --path <fragment> for its own reach."


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


def report_path(relpath, added_bytes, rule_sizes, agent_sizes, budgets, fanout, reach):
    """--report --path <relpath> [--added-bytes <n>] body. Returns (text, rc).

    rc is 2 when relpath is not a repo-relative path under shared/rules/
    (the CLI's own usage contract — the hook never calls this with anything
    else, but a human operator might)."""
    if not (relpath.startswith("shared/rules/") or relpath in agent_sizes):
        return (
            f"prompt_size_budget: --path must be a repo-relative path under shared/rules/ "
            f"(or a rendered agent prompt .md.j2 source), got {relpath!r}",
            2,
        )

    lines = [f"prompt_size_budget --report --path {relpath}"]

    # Own-row projection is LINE-counted (the rule file's own committed unit);
    # --added-bytes is a BYTE count (the unit every downstream rendered prompt
    # is measured in, and what the hook can actually compute from an Edit/
    # Write/MultiEdit payload). The two units are not interchangeable — a
    # byte delta is never assumed to equal a line delta — so this section
    # reports the own row's CURRENT state only; the projection lives entirely
    # in the byte-measured fan-out section below, which is what a net-additive
    # rule-fragment edit actually threatens.
    if relpath in rule_sizes:
        current = rule_sizes[relpath]
        budget = effective_ceiling(relpath, current, budgets)
        headroom = budget - current
        row_kind = "committed row" if relpath in budgets else "derived STYLE_GUIDE ceiling (no committed row)"
        lines.append(
            f"  own row ({row_kind}): {current} lines now, {budget} lines budget, "
            f"{headroom} lines headroom"
        )
    elif relpath in agent_sizes:
        lines.append("  (this path IS a rendered agent prompt source, not a rule fragment — see below)")

    reached = fanout.get(relpath, [])
    if not reached:
        lines.append(f"  reaches 0 rendered prompts")
        return ("\n".join(lines), 0)

    lines.append(f"  reaches {len(reached)} rendered prompt(s):")
    total_evict = 0
    for prompt in reached:
        now = agent_sizes.get(prompt)
        budget = budgets.get(prompt)
        if now is None or budget is None:
            lines.append(f"    - {prompt}: (unmeasured or no committed row)")
            continue
        headroom = budget - now
        if added_bytes:
            projected = now + added_bytes
            over = projected - budget
            if over > 0:
                lines.append(
                    f"    - {prompt}: {now} B now, {headroom} B headroom -> "
                    f"+{added_bytes} B OVERFLOWS by {over} B — evict >= {over} B in this pass"
                )
                total_evict = max(total_evict, over)
            else:
                lines.append(f"    - {prompt}: {now} B now, {headroom} B headroom -> +{added_bytes} B fits")
        else:
            lines.append(f"    - {prompt}: {now} B now, {headroom} B headroom")

    if added_bytes and total_evict > 0:
        lines.append(f"  evict >= {total_evict} B in this pass to fit the tightest reached prompt")

    return ("\n".join(lines), 0)


def report_whole_corpus(rule_sizes, agent_sizes, budgets, fanout):
    """--report (no --path) — the whole-corpus meter. KEEP-ADVISORY, no
    automated caller — see module docstring."""
    lines = ["prompt_size_budget --report (whole corpus)", "", "rendered prompts (now / budget / headroom):"]
    for relpath in sorted(agent_sizes):
        now = agent_sizes[relpath]
        budget = budgets.get(relpath)
        if budget is None:
            lines.append(f"  {relpath}: {now} B / (no committed row)")
        else:
            lines.append(f"  {relpath}: {now} B / {budget} B / {budget - now} B headroom")
    lines.append("")
    lines.append("rule fragments (fan-out -> tightest downstream headroom):")
    for relpath in sorted(fanout):
        reached = fanout[relpath]
        tightest = None
        for prompt in reached:
            now = agent_sizes.get(prompt)
            budget = budgets.get(prompt)
            if now is None or budget is None:
                continue
            headroom = budget - now
            if tightest is None or headroom < tightest:
                tightest = headroom
        tightest_str = f"{tightest} B" if tightest is not None else "n/a"
        lines.append(f"  {relpath}: fan-out {len(reached)} -> tightest headroom {tightest_str}")
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
    parser.add_argument(
        "--report",
        action="store_true",
        help="read-only reach projection — whole corpus, or --path <relpath> for one fragment",
    )
    parser.add_argument(
        "--path",
        default=None,
        help="repo-relative path (with --report) to project reach/headroom for",
    )
    parser.add_argument(
        "--added-bytes",
        dest="added_bytes",
        type=int,
        default=None,
        help="with --report --path: bytes/lines being added, to project overflow",
    )
    args = parser.parse_args()

    if not args.check and not args.write and not args.report:
        args.check = True  # default action

    if args.report and args.path is None and args.added_bytes is not None:
        print("prompt_size_budget: --added-bytes requires --path", file=sys.stderr)
        return 2

    if args.added_bytes is not None and args.added_bytes < 0:
        print(
            f"prompt_size_budget: --added-bytes must be a non-negative integer, got {args.added_bytes}",
            file=sys.stderr,
        )
        return 2

    rule_sizes = measure_rule_files()
    agent_sizes = measure_agent_prompts()

    if args.write:
        rendered = render_budget_file(rule_sizes, agent_sizes)
        BUDGET_FILE.write_text(rendered)
        print(f"prompt_size_budget: wrote {BUDGET_FILE} ({len(rule_sizes)} rule files, {len(agent_sizes)} agent prompts)")
        return 0

    if args.report:
        budgets = parse_budget_file(BUDGET_FILE)
        fanout, reach = build_include_graph()
        if args.path is not None:
            text, rc = report_path(
                args.path, args.added_bytes or 0, rule_sizes, agent_sizes, budgets, fanout, reach
            )
            print(text)
            return rc
        print(report_whole_corpus(rule_sizes, agent_sizes, budgets, fanout))
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

    notices = []
    _fanout, reach = build_include_graph()

    for relpath, actual in sorted(all_sizes.items()):
        if relpath not in budgets:
            if relpath in agent_sizes:
                # A rendered agent prompt has no STYLE_GUIDE target to derive
                # from, and a new one only appears when an operator adds a
                # subagent template. Seeding its ceiling is a real operator
                # decision, so this stays a hard fail — but say which command,
                # and that it is the operator's to run.
                failures.append(
                    f"{relpath}: new rendered agent prompt with no committed budget row. "
                    "There is no derivable ceiling for an agent prompt — an operator must "
                    "seed one: python3 templates/generator/prompt_size_budget.py --write"
                )
                continue
            budget = derived_ceiling(relpath)
            if actual > budget:
                failures.append(
                    f"{relpath}: {actual} lines exceeds the STYLE_GUIDE ceiling {budget} lines "
                    "for a NEW rule file (no committed row — new files are held to the "
                    "STYLE_GUIDE target, not to a grandfathered ceiling). Shrink it."
                )
            continue
        budget = budgets[relpath] if relpath in agent_sizes else effective_ceiling(relpath, actual, budgets)
        if actual > budget:
            unit = "bytes" if relpath in agent_sizes else "lines"
            attribution = ""
            if relpath in agent_sizes:
                attribution = attribute_prompt_overage(relpath, reach, rule_sizes)
            failures.append(
                f"{relpath}: {actual} {unit} exceeds committed budget {budget} {unit}.{attribution}"
            )

    # A budget row naming a file that no longer exists is stale. It is NOT a
    # size violation — a deleted file cannot overflow anything — and its only
    # remedy (--write) is denied to every agent, so failing on it deadlocked
    # the role that deleted or renamed the file. Reported, not fatal: the
    # operator prunes it, and until they do the derived ceiling above governs
    # any file that later takes the name (stricter than the orphaned row).
    for relpath in sorted(budgets):
        if relpath not in all_sizes:
            notices.append(f"{relpath}: budget row present but file no longer exists — stale row")

    if notices:
        print("prompt_size_budget: stale budget row(s) — operator prune with --write:", file=sys.stderr)
        for n in notices:
            print(f"  - {n}", file=sys.stderr)

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
