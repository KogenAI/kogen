# AGENTS.md - Hybrid Workspace

Universal guidance for AI agents in hybrid workspaces — production agent quality without worktrees or planning overhead.

**Hybrid = full agent delegation chain + no worktrees + no planning phase + no CONTEXT.md**

## 🚨 ORCHESTRATOR: NEVER IMPLEMENT CODE DIRECTLY

The orchestrator NEVER writes code, tests, or file edits — not even "small" ones.

❌ **FORBIDDEN**: Writing tests, editing source files, fixing bugs inline, "just quickly" adding anything

✅ **ONLY allowed**: Loading rules, reading context, creating session log, delegating to subagents, committing after all gates pass

**Any code or tests → delegate to feature-developer immediately. No exceptions.**

## 🚨 ORCHESTRATOR: ALWAYS RUN THE FULL CYCLE

**After feature-developer completes — immediately, without stopping or asking:**

1. **Identify the step's gate** — what test suite proves this works? CI alone? `make llm-phoenix`? Write it in the session log.
2. → **verification-engineer** (runs `./codegen/ci.sh` AND the step's gate)
3. → **code-reviewer** (only after "ALL CLEAR ✅")
4. → **commit** (only after "✅ QUALITY APPROVED")
5. → **continue to next step** — do NOT stop after committing

**No exceptions.** One-line change? Full cycle. Runtime.exs tweak? Full cycle.

## ⚠️ MANDATORY: Load Rules FIRST

On EVERY session start:

1. **LOAD** `./codegen/rules/orchestration/delegation-patterns.md` and `./codegen/rules/orchestration/user-communication.md`
2. **READ** `./codegen/PROJECT_CONTEXT.md`

## Repository & Symlink Layout

```
./                      ← combobulate platform source
  codegen/
    PROJECT_CONTEXT.md  → symlink to ../PROJECT_CONTEXT.md (project-specific)
    rules/              → symlink to shared context repo rules
    recipes/            → symlink to shared context repo recipes
    logging/            ← session logs (local)
  ../infra/             ← infra docs (sibling repo)
    README.md, operations.md, deploy/, setup/
```

`./codegen/rules/` and `./codegen/recipes/` are symlinks — edits affect ALL projects.

## 🔍 Debugging Sessions

Read infra docs FIRST (`../infra/README.md`), then the relevant doc:

- **Server/ops** → `operations.md` | **Platform** → `deploy/platform.md` | **Static sites** → `deploy/static_sites.md`
- **Caddy/DNS** → `setup/caddy.md` | **PostgreSQL** → `setup/databases.md` | **Env vars** → `setup/environment_variables.md`

SSH: `ssh root@46.225.1.182`, then `su - combobulate`. **Never ask the user to run debug commands** — SSH in directly.

## Workspace Rules

- Work in current directory only (never `../`)
- No worktrees — commit directly to main
- No planning phase — implement from task description directly

## 📊 Session Logging

**Orchestrator** creates the session log as FIRST action. **Subagents append** — never create separate files.

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`

See `shared/session-management.md` for the complete log format.

## Agent Roles & Workflow

```
feature-developer → verification-engineer → code-reviewer → orchestrator commits
```

- **feature-developer**: Implements feature + tests (TDD), updates PROJECT_CONTEXT.md before reporting done
- **verification-engineer**: Runs `./codegen/ci.sh`, reports ALL failures, never fixes code
- **code-reviewer**: Reviews quality/patterns/architecture, reports issues
- **orchestrator**: Uses `Skill("commit")` after all gates pass

## 🔄 MANDATORY: Update PROJECT_CONTEXT.md Before Handoff

feature-developer MUST update before reporting done: new modules → Module Directory, changed patterns → relevant section, new pitfalls → Common Pitfalls.

## 🔄 MANDATORY: Update PLATFORM_INFO.md When Flow Changes

feature-developer MUST update `./PLATFORM_INFO.md` when customer-facing flows change. Bouncer loads it on every Haiku call — stale info = wrong answers to users.

## CI Setup

**`./codegen/ci.sh`** runs `make ci`: compile → deps.unlock → deps.audit → hex.audit → sobelow → format + prettier → credo --strict → dialyzer → test --cover → ecto.rollback

## LLM Integration Tests

**Always use `make` targets** — never construct `mix test` commands manually.

- `make llm` — all LLM tests in parallel (~3-4 min)
- `make llm-summary` — failure summary from last run
- `make llm-retry` — rerun only failed tests
- `make llm-kill` — kill background partitions after Ctrl+C
- Single test: `MIX_TEST_PARTITION=1 MIX_TEST_PARTITIONS=1 mix test --only llm_integration path/to/test.exs`

**Run when diff touches**: system prompts, `parse_build_result`, any `CLAUDE.md` or `codegen/rules/` file, role templates (`.md.j2`), `claude_runner_impl.ex`, `claude_build_runner_impl.ex`, `bouncer.ex`, Claude prompt strings in any module, LLM test infrastructure. **Skip for all other changes.**

**🚨 Orchestrator**: Check the diff before delegating to verification-engineer. If it touches any of the above, tell them the gate includes LLM tests.

**🚨 Applies to debugging too.** Editing CLAUDE.md, context repo files, or system prompts — even as a "quick fix" — requires LLM tests before committing.

**Test naming**: `<app_type>_<stack>_<scenario>_test.exs`. Stacks: HTML, Hugo, React, Vue, Phoenix, multilingual. See `codegen/llm_integration_test_coverage.md` for file list and phone registry.

**When LLM tests fail**: Run in isolation to confirm. Check `main` before claiming "pre-existing". Fix prompts/rules until it passes. Never dismiss as "nondeterminism".

## Universal Requirements

- **Read PROJECT_CONTEXT.md first** — always, before any work
- **Issue Discovery → Immediate Fixing** — find issues, fix them, never just document
- **Session logging** — orchestrator creates, subagents append
- **Update PROJECT_CONTEXT.md before done** — feature-developer must update before handoff
