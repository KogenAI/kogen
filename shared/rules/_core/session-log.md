# Session Log

## File Naming

Canonical schema (single source of truth — hooks and guards match against this):

```
codegen/logging/[0-9]{8}_[0-9]{6}(_[a-z0-9_-]+)?_(session|step[0-9]+_[a-z0-9_-]+)\.md$
```

- Single: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)[_<slug>]_session.md`
- Multi-step: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step<N>_<slug>.md`

## Path Discipline

ALL roles MUST use relative paths OR absolute paths starting with cwd for session logs, project files, and git operations.

## Git Status

Session logs live under `/codegen/` and are **gitignored** — in the codegen repo (`.gitignore`) and in every scaffolded downstream app (both stacks, appended by `codegen-scaffold` integrate). They are **ephemeral working artifacts — never committed, never durable**.

- NEVER `git add` a session log or include one in a commit. `git add -A` already skips gitignored logs.
- NEVER make a separate "record the log" commit — git refuses the ignored path (`exit 1`, "paths are ignored… Use -f") and the log never registers dirty under `git status --porcelain`, so nothing is missing.

## Ownership

- Orchestrator creates log FIRST via **`codegen-log init --slug <slug>`** (Bash), not raw Edit/Write, and never via Bash redirect.
- `codegen-log section --body @-` is the sole section writer: planner, developers, reviewer, curator, and committer each write their own body atomically at canonical rank.
- Subagents write body under the canonical section header via the writer — never emit or pre-seed placeholder headers themselves.
- Header-only sections are invalid: every required section must contain non-heading body content before the next role may spawn or the build may ship.
- Never use a full-file Write/Edit to mutate `codegen/logging/*.md`; the writer owns insertion/replacement and keeps the section order stable.
- Multi-step → orchestrator maintains `./codegen/logging/$(date -u +%Y%m%d)_progress.md`.

## Death Stamps

When a subagent drops mid-response, the orchestrator records it INSIDE the dead role's section as an H3 marker (H3 so it never participates in the H2 canonical-order check):

- `### INTERRUPTED ⚠️ — <role> dropped (<cause>); re-spawning (attempt N/2)` — written when the drop tool_result is observed.
- `### RESUMED` — written when the re-spawn produces real output.
- `### ABORTED 💀 — <role> dropped twice; stage failed.` — written on re-spawn exhaustion, then the stage halts.

A section carrying `### INTERRUPTED ⚠️` or `### ABORTED 💀` is in-recovery: the `step-log-completeness` Stop hook skips its empty-body floor for that section (mirrors the existing `INCONCLUSIVE ⚠️` skip).

## Canonical Section Order

Session log sections MUST appear in this non-decreasing phase order (rank):

| Rank | Header pattern               |
| ---- | ---------------------------- |
| 1    | `## Version Stamp`           |
| 2    | `## Rules Loaded` (optional) |
| 3    | `## Plan` / `## Slices`      |
| 4    | `## Delegation Timeline`     |
| 5    | `## Files Modified`          |
| 6    | `## developer-* Section`     |
| 8    | `## reviewer-* Section`      |
| 9    | `## context-curator Section` |
| 10   | `## committer Section`       |

Only `## ` (H2) headers participate in the order check. H1 title lines (`# Step N`) and sub-headers (`### `) are ignored to avoid false-positives from code-block comment lines. Unknown/freeform `## ` headers are also ignored. Recognized `## ` headers must appear in non-decreasing rank order — a `## reviewer-* Section` before `## developer-* Section` is forbidden. The `session-log-structure` hook enforces this at Edit/Write time.

## Enforcement

**Enforced by** ~24 hooks (naming, discovery, section integrity, write-allowlist, cycle/stop, retrospective) — catalog in `context/hooks.md`; enumerate via `grep -rlE 'session.?log|codegen/logging' harnesses/claude/hooks/*.sh`.

## Step Log Skeleton

```markdown
## Version Stamp

- project: <hash>
- context: <hash>
- codegen: <hash>
- claude: <version>
- stamped_at: <iso timestamp>

## Plan

<planner fills in>

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |

## Files Modified

(populated by dev)
```

## Subagent Section

```markdown
## <role> Section

**Rules loaded**: [x] <files>

**Commands executed**:
| Time (HH:MM:SS UTC) | Command | Exit | Notes |
| ------------------- | ------- | ---- | ----- |

**Files written/updated**: <list>

**Result**: <summary>

### What I Learned This Step

- nothing notable
```

**Critical ordering**: `### What I Learned This Step` MUST appear BEFORE any `## ` sub-header (e.g., `## Files Modified`, `## Next Steps`). Hooks extract retrospectives via awk section scanning; a `## ` header inside the section body terminates extraction and prevents subsequent `### What I Learned ...` blocks from being read. Violations silently hide learnings from curation. Pattern: result summary → retrospective block → then any `## ` sub-headers (if needed). **Note**: The retrospective-guard awk scan does NOT fence-skip — literal `## ` headers inside fenced code blocks (e.g., `json ... ##... `) are treated as section terminators. Place `### What I Learned This Step` as the **FIRST block** under `## Plan` (before any code/prose with `## ` lines inside) to prevent early termination of the extraction.

Tags: `[local]` = project-specific. `[shared]` = framework idioms, cross-cutting patterns.

Retrospective placement: `### What I Learned This Step` for planner variants MUST sit inside `## Plan` body.

## Gate Verdict Authority

Gate hooks write `gate-result.json` with a `.verdict` field (`"passed"` or `"failed"`). **The `.verdict` JSON field is the authoritative gate result — never cosmetic log strings.** When a reviewer or orchestrator evaluates a gate hook's outcome, read `.verdict` from `gate-result.json`, not prose like "ALL CLEAR ✅" in the session log body. Log strings may reflect developer's intended state; JSON reflects the actual gate return code. Example: developer logs claim "ALL CLEAR ✅ on retry" but `gate-result.json` shows `.verdict: "failed"` — the JSON is authoritative and the gate truly failed.

## Citations

Cite `Module.function/arity` — never `file.ex:NN`. No module → section heading or unique nearby string.
