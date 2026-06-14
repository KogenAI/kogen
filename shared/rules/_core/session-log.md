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

Tags: `[local]` = project-specific. `[shared]` = framework idioms, cross-cutting patterns.

Retrospective placement: `### What I Learned This Step` for planner variants MUST sit inside `## Plan` body.

## Citations

Cite `Module.function/arity` — never `file.ex:NN`. No module → section heading or unique nearby string.
