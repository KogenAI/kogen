# Session Log

## File Naming

Canonical schema (single source of truth — hooks and guards match against this):

```
codegen/logging/[0-9]{8}_[0-9]{6}(_[a-z0-9_-]+)?_(session|step[0-9]+_[a-z0-9_-]+)\.md$
```

- Single: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)[_<slug>]_session.md` (slug optional)
- Multi-step: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step<N>_<slug>.md` (full %H%M%S, not date-only)

## Path Discipline

**ALL roles** (orchestrator, planner, dev, reviewer, committer) MUST use relative paths OR absolute paths that start with the cwd when:

- Creating/updating session logs (`./codegen/logging/*.md`)
- Editing project files via Edit tool (`./lib/`, `./test/`, `./bin/`, `./priv/`, etc.)
- Running git operations (`git diff`, `git log`, `git add`, `git status` — all relative to project root)

<!-- DELIBERATE LOOSENING from prior 'absolute paths FORBIDDEN' wording:
     cwd-discipline.md line 10 permits absolute paths that start with cwd.
     This rule now aligns with that. Hooks (reviewer-guard, orchestrator-*)
     normalise FILE_PATH via repo_relative() before pattern matching, so
     both relative and abs-in-cwd forms pass guards correctly. -->

Use relative paths OR absolute paths THAT START WITH the cwd you were given; see `cwd-discipline.md` for path-form authority. Absolute paths to unrelated directories are FORBIDDEN.

## Ownership

- Orchestrator creates session log FIRST — BEFORE delegating to planner, for ALL prompt types (pitch-driven, free-form, slash-command, `claude-build` non-interactive).
  - Same slug exists → read; committed → skip.
  - Free-form prompt (no pitch file) → use single-session form `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`.
  - Multi-step (`/split` or explicit step plan) → use `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_step<N>_<slug>.md`.
- Orchestrator inserts `## <agent_type> Section` header into the session log via Edit BEFORE each `Agent()` call (delegation-time Edit, not Step-0).
- Subagents write their section body under the existing header — never emit the header themselves. Hook `session-log-section-integrity.sh` lines 50–66 bypass: file already contains expected header → Edit allowed.
- Planner exception: writes to `## Plan` (top-level skeleton header), not `## planner Section`. Hook line 35 bypasses `AGENT_TYPE=planner` literal only — stack-prefixed planner variants (`planner-phoenix`, `planner-html`, etc.) REQUIRE a stub `## planner-<stack> Section` header (literal stack name) in any Edit payload. The hook's bypass (line 35) does not widen to stack-prefixed variants; they must satisfy the normal `session-log-section-integrity.sh` header-present rule (lines 50–66).
- Multi-step → orchestrator maintains `./codegen/logging/$(date -u +%Y%m%d)_progress.md`.

Session log creation MUST use the `Write` tool, NEVER a Bash heredoc/redirect (`cat > ... <<EOF`, `echo ... >`, `tee`). Reason: `phoenix-dev-gate.sh` and `step-log-missing-guard.sh` discover the active log via `session_log_from_transcript` (`harnesses/claude/hooks/lib/hooks-lib.sh`), which filters transcript JSONL for `Write|Edit|MultiEdit` tool_use entries on `codegen/logging/*.md`. Bash redirects appear as `Bash` tool_use entries → invisible to the discovery query → gate hook silently skips, no verdict appended.

Enforcement: `step-log-missing-guard.sh` (Stop hook) detects "developer-\* subagent ran but no session log Write in transcript" and re-enters the orchestrator with a block instruction. The gate hook (`phoenix-dev-gate.sh`) silently skips when no session log exists in the transcript — this is by design; the missing-guard hook is what catches the violation.

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

<!--
Expected sections (orchestrator inserts the concrete header BEFORE each delegation;
subagent writes its body under the existing header — does NOT append its own).
Canonical names matched by hooks/curators:
  ## developer-phoenix-backend Section  (or developer-phoenix-frontend, developer-html, developer-hugo, developer-vite)
  ## dev-gate Section                   (or phoenix-dev-gate, static-site-verifier on static stacks)
  ## reviewer-phoenix Section           (or reviewer-static)
  ## context-curator Section
  ## committer Section
Planner writes to `## Plan` above — no `## planner Section`.
-->
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

OR, when something surfaced worth recording:

```markdown
### What I Learned This Step

- [local] <combobulate-specific observation, e.g. module path, schema field, context name>
- [shared] <cross-project pattern, e.g. Elixir idiom, framework quirk, language style rule>
```

Tags: `[local]` = combobulate-specific (module names, file paths, schemas, business logic). `[shared]` = framework idioms, cross-cutting patterns, language style.

Context curator reads all `### What I Learned This Step` blocks from a single cycle — accumulating across dev, reviewer, and any retry loops — in one run post-final-reviewer.

Every Bash invocation → one row. Update continuously, no end-of-session batching.

**Retrospective placement**: `### What I Learned This Step` blocks MUST sit inside the `## Plan` body (under `## Plan`, before any H2 headings like `## Slices`), NOT under the `## planner-<stack> Section` header. Hook `subagent-retrospective-guard.sh` scans the `## Plan` block to extract retrospectives for context-curator routing; it stops scanning at the next H2 heading.

## Citations

Cite `Module.function/arity` — never `file.ex:NN`.

❌ `bouncer.ex:519`
✅ `Bouncer.resolve_intent/2`

No module (config, migrations) → section heading or unique nearby string.
