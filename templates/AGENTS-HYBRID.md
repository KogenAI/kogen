# AGENTS.md - Hybrid Workspace

Universal guidance for AI agents in hybrid workspaces — production agent quality without worktrees or CONTEXT.md files.

**Hybrid = full agent delegation chain + no worktrees + Opus planner as Phase 0 + no CONTEXT.md**

## ORCHESTRATOR: NEVER IMPLEMENT CODE DIRECTLY

The orchestrator NEVER writes code, tests, or file edits — not even "small" ones.

- **FORBIDDEN**: Writing tests, editing source files, fixing bugs inline, "just quickly" adding anything
- **ONLY allowed**: Loading rules, reading context, creating session log, delegating to subagents (including committer)

**Any code or tests -> delegate to phoenix-developer or static-site-developer (pick by app stack). No exceptions.**

## ORCHESTRATOR: ALWAYS RUN THE FULL CYCLE

**Phase 0 — planner** (skip only when ALL THREE are true):

1. Task is a bug fix or CI-failure fix (message contains `bug`, `fix`, `failing`, `error`, `broken`, `crash`)
2. No new module, table, migration, endpoint, or external API mentioned (message lacks `add`, `new`, `create`, `integrate`, `implement`)
3. Scope fits in one domain context file (task mentions at most one of: messaging, hosting, builds, billing, auth, email, development)

If any is false → engage planner. For user-app builds, planner always runs.

**After the developer subagent completes — immediately, without stopping or asking:**

1. **Identify the step's gate** — what test suite proves this works? CI alone? Write it in the session log.
2. -> **verification-engineer** (runs `make ci` AND the step's gate)
3. -> **code-reviewer** (only after "ALL CLEAR")
4. -> **committer** (only after "QUALITY APPROVED" — pass the task summary so it can craft a why-focused message)
5. -> **continue to next step** — do NOT stop after committing

**No exceptions.** One-line change? Full cycle. Runtime.exs tweak? Full cycle.

## MANDATORY: Load Rules FIRST

On EVERY session start:

1. **LOAD** `./codegen/rules/orchestration/delegation-patterns.md` and `./codegen/rules/orchestration/user-communication.md`
2. **READ** `./codegen/PROJECT_CONTEXT.md` (concise index — always load)

## Domain Context Loading

`PROJECT_CONTEXT.md` is a concise index. Detailed context lives in `context/` domain files. Agents load the index always, then only the domain file(s) relevant to their task.

See the "Domain Context Files" table in `PROJECT_CONTEXT.md` for the loading guide.

**Orchestrator**: tell subagents which domain context file(s) to load in the delegation prompt.

## Workspace Rules

- Work in current directory only (never `../`)
- No worktrees — commit directly to main
- Planner (Phase 0) runs before the developer subagent for all non-trivial tasks (see skip rule above)

## Session Logging

**One log per step/task.** Multi-step sessions produce one file per step + a progress file.

- **Orchestrator** creates each step's log file before delegating
- **Subagents** append their section — never create separate files
- Multi-step progress: `./codegen/logging/$(date -u +%Y%m%d)_progress.md`
- Step logs: `./codegen/logging/$(date -u +%Y%m%d)_step<N>_<slug>.md`
- Single-task: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`

Session log template (create BEFORE delegating to planner):

```markdown
# Session Log

**Started**: $(date -u)
**Task**: [What you're doing]

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

- **planner**: Reads codebase, writes structured plan to session log `## Plan` section (Opus — deep analysis)
- **phoenix-developer**: Reads `## Plan` from session log, implements Phoenix/Elixir feature + tests (TDD), updates context files before reporting done
- **static-site-developer**: Reads `## Plan` from session log, implements static site source files, updates context files before reporting done
- **verification-engineer**: Runs `make ci`, reports ALL failures, never fixes code
- **code-reviewer**: Reviews quality/patterns/architecture, reports issues
- **committer**: Receives task summary from orchestrator, analyzes git diff, crafts why-focused commit message, stages and commits (Haiku — cheap and fast)

## MANDATORY: Update Context Before Handoff

The developer subagent MUST update before reporting done:

- `PROJECT_CONTEXT.md` — if module directory changes
- Relevant `context/*.md` domain file — new modules, env vars, pitfalls for that domain

## CI Setup

**`make ci`**: compile -> deps.unlock -> deps.audit -> hex.audit -> sobelow -> format + prettier -> credo --strict -> dialyzer -> test --cover -> ecto.rollback

## Universal Requirements

- **Read PROJECT_CONTEXT.md first** — always, before any work. Never assume field names, module paths, or schema structure — check PROJECT_CONTEXT and relevant domain context files before writing queries or code.
- **Load relevant domain context** — based on task, not all files
- **Issue Discovery -> Immediate Fixing** — find issues, fix them, never just document
- **Session logging** — orchestrator creates, subagents append
- **Update context before done** — the developer subagent must update index + domain file before handoff
