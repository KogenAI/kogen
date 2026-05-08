# AGENTS.md - Hybrid Workspace

Guidance for AI agents in hybrid workspaces — production agent quality without worktrees or CONTEXT.md files.

**Hybrid = full agent delegation chain + no worktrees + Opus planner as Phase 0 + no CONTEXT.md**

## ORCHESTRATOR: NEVER IMPLEMENT CODE DIRECTLY

Orchestrator NEVER writes code, tests, or file edits.

- **FORBIDDEN**: Writing tests, editing source files, fixing bugs inline
- **ONLY allowed**: Loading rules, reading context, creating session log, delegating to subagents

**Any code or tests → delegate to phoenix-developer or static-site-developer. No exceptions.**

## ORCHESTRATOR: ALWAYS RUN THE FULL CYCLE

**Phase 0 — planner** (skip only when ALL THREE are true):

1. Task is bug fix or CI-failure fix (message contains `bug`, `fix`, `failing`, `error`, `broken`, `crash`)
2. No new module, table, migration, endpoint, or external API (message lacks `add`, `new`, `create`, `integrate`, `implement`)
3. Scope fits in one domain context file

If any is false → engage planner. For user-app builds, planner always runs.

**After dev subagent completes — immediately, without stopping:**

1. **Identify gate** — what test suite proves this works? Write in session log.
2. → **verification-engineer** — first line of delegation: `Gate: <exact command from planner's plan>`. Never derive independently — re-read `## Plan` section.
3. → **code-reviewer** — ONLY after finding literal `ALL CLEAR ✅` in ve section. If absent, re-delegate to dev.
4. → **committer** (only after "QUALITY APPROVED" — pass task summary)
5. → **continue to next step** — do NOT stop after committing

**No exceptions.** One-line change? Full cycle. Runtime.exs tweak? Full cycle.

**Multi-step tasks**: Steps pre-sequenced by `/split`. Run planner once per step, then full cycle. Never bundle steps.

## Output Style

Output: caveman ultra. Agents read you, not humans. No preamble. No recap. No pleasantries. Drop articles, filler, hedging. Fragments OK. Arrows for causality (X → Y). Short synonyms (fix not "implement a solution"). Inline acronyms (dev, VE, impl, DB, conn, fn, reqs). NEVER touch JSON schemas, Ecto field names, contracts, code blocks, error strings, "MUST"/"NEVER"/"FORBIDDEN", or hook markers (ALL CLEAR ✅, FAILED ❌, INCONCLUSIVE ⚠️) — verbatim regardless of style. Drop ultra for security warnings or irreversible-action confirmations.

## MANDATORY: Load Rules FIRST

Orchestrator-only rules — subagents have rules pre-loaded via Jinja includes.

On EVERY session start:

1. **LOAD** `./codegen/rules/orchestration/delegation-patterns.md`, `./codegen/rules/orchestration/user-communication.md`, and `./codegen/rules/orchestration/deploy.md`
2. **READ** `./codegen/PROJECT_CONTEXT.md`

## Domain Context Loading

`PROJECT_CONTEXT.md` is concise index. Detailed context in `context/` domain files. Agents load index always, then only relevant domain files.

See "Domain Context Files" table in `PROJECT_CONTEXT.md`.

**Orchestrator**: tell subagents which domain context files to load in delegation prompt.

## Workspace Rules

- Work in current directory only (never `../`)
- No worktrees — commit directly to main
- Planner (Phase 0) runs before dev for all non-trivial tasks

## Session Logging

**One log per step/task.** Multi-step sessions → one file per step + progress file.

- **Orchestrator** creates each step's log before delegating
- **Subagents** append their section — never create separate files
- Multi-step progress: `./codegen/logging/$(date -u +%Y%m%d)_progress.md`
- Step logs: `./codegen/logging/$(date -u +%Y%m%d)_step<N>_<slug>.md`
- Single-task: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`

Create BEFORE delegating to planner. Then stamp:

```bash
{
  echo ""
  echo "## Version Stamp"
  echo ""
  echo "- combobulate: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- context: $(git -C ./codegen/context rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- codegen: $(git -C ./codegen/rules rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "- claude: $(claude --version 2>/dev/null || echo unknown)"
  echo "- stamped_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} >> <SESSION_LOG>
```

```markdown
# Session Log

**Started**: $(date -u)
**Task**: [What you're doing]

## Version Stamp

- combobulate: <hash>
- context: <hash>
- codegen: <hash>
- claude: <version>
- stamped_at: <iso timestamp>

## Rules Loaded

- [x] codegen/PROJECT_CONTEXT.md
- [x] codegen/rules/orchestration/delegation-patterns.md

## Plan

<planner fills this in>

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |

## Files Modified
```

See `shared/session-management.md` for full format.

## Agent Roles & Workflow

```
planner -> phoenix-developer OR static-site-developer -> verification-engineer -> code-reviewer -> committer
```

- **planner**: Reads codebase, writes structured plan to session log `## Plan` section (Opus)
- **phoenix-developer**: Reads `## Plan`, implements Phoenix/Elixir feature + tests (TDD), updates context before done
- **static-site-developer**: Reads `## Plan`, implements static site files, updates context before done
- **verification-engineer**: Runs `make ci`, reports ALL failures, never fixes code
- **code-reviewer**: Reviews quality/patterns/architecture, reports issues
- **committer**: Receives task summary, analyzes git diff, crafts why-focused commit message, stages and commits

### Static-site verification

Static-site builds collapsed into deterministic SubagentStop hook — `static-site-build-check.sh` — runs `mise exec -- npm run build`, asserts `package.json` invariants, rejects Tailwind v3 config files/directives. Hook fires automatically after `static-site-developer` done; on failure emits `decision: block` → developer re-spawned. No orchestrator delegation step needed.

Subagent rules baked into each agent's system prompt via Jinja `{% include %}` — subagents do not Read them at session start.

## MANDATORY: Update Context Before Handoff

Dev subagent MUST update before done:

- `PROJECT_CONTEXT.md` — if module directory changes
- Relevant `context/*.md` domain file — new modules, env vars, pitfalls

## CI Setup

**`make ci`**: compile → deps.unlock → deps.audit → hex.audit → sobelow → format + prettier → credo --strict → dialyzer → test --cover → ecto.rollback

## Universal Requirements

- **Read PROJECT_CONTEXT.md first** — always. Never assume field names, module paths, or schema structure.
- **Load relevant domain context** — based on task, not all files
- **Issue Discovery → Immediate Fixing** — find issues, fix them, never document only
- **Session logging** — orchestrator creates, subagents append
- **Update context before done** — dev must update index + domain file before handoff
