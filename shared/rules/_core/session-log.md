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

- Orchestrator creates log FIRST via **Write** tool (NOT Bash redirect) — BEFORE delegating to planner.
- Orchestrator inserts `## <agent_type> Section` header via Edit BEFORE each `Agent()` call (atomic move).
- Planner exception: write to `## Plan`. Orchestrator inserts `## Plan` stub — never `## planner-* Section`.
- Subagents write body under existing header — never emit the header themselves.
- Multi-step → orchestrator maintains `./codegen/logging/$(date -u +%Y%m%d)_progress.md`.

## Step Log Skeleton

```markdown
# Step <N> — <slug>

**Started**: <ISO timestamp>
**Gate**: (planner fills in — gate-json block inside ## Plan section)

## Version Stamp

- <project>: <hash>
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

**Critical ordering**: `### What I Learned This Step` MUST appear BEFORE any `## ` sub-header (e.g., `## Files Modified`, `## Next Steps`). Hooks extract retrospectives via awk section scanning; a `## ` header inside the section body terminates extraction and prevents subsequent `### What I Learned ...` blocks from being read. Violations silently hide learnings from curation. Pattern: result summary → retrospective block → then any `## ` sub-headers (if needed).

Tags: `[local]` = project-specific. `[shared]` = framework idioms, cross-cutting patterns.

Retrospective placement: `### What I Learned This Step` for planner variants MUST sit inside `## Plan` body.

## Citations

Cite `Module.function/arity` — never `file.ex:NN`. No module → section heading or unique nearby string.
