# AGENTS.md - Hybrid Workspace

Universal guidance for AI agents in hybrid workspaces — production agent quality without worktrees or planning overhead.

**Hybrid = full agent delegation chain + no worktrees + no planning phase + no CONTEXT.md**

> ⚠️ "Hybrid" means no worktrees/planning overhead — it does NOT mean the orchestrator implements code.
> The orchestrator ALWAYS delegates. See delegation-patterns.md.

## 🚨 ORCHESTRATOR: NEVER IMPLEMENT CODE DIRECTLY

**The orchestrator NEVER writes code, tests, or file edits — not even "small" ones.**

❌ **FORBIDDEN for orchestrator**:

- Writing tests directly
- Editing source files
- Fixing bugs inline
- "Just quickly" adding a function or describe block

✅ **ONLY allowed for orchestrator**:

- Loading rules and reading context
- Creating the session log
- Delegating tasks to subagents (feature-developer, verification-engineer, code-reviewer)
- Committing after all gates pass

**If the task involves writing ANY code or tests → delegate to feature-developer immediately.**

No exceptions. Not even for one-line changes. Not even for "simple" test additions.

## 🚨 ORCHESTRATOR: ALWAYS RUN THE FULL CYCLE

**After feature-developer completes, you MUST immediately (without stopping, without asking) delegate:**

1. → **verification-engineer** (runs `./codegen/ci.sh`, reports ALL failures)
2. → **code-reviewer** (only after verification-engineer reports "ALL CLEAR ✅")

**FORBIDDEN**:

- ❌ Stopping after feature-developer reports done
- ❌ Asking the user "should I run verification?"
- ❌ Reporting completion before code-reviewer says "✅ QUALITY APPROVED"

**The cycle is ALWAYS**: feature-developer → verification-engineer → code-reviewer → done

## ⚠️ MANDATORY: Load Rules FIRST

**CRITICAL - On EVERY session start, including greetings like "Hi":**

1. **STOP** - Do NOT respond to the user until rules are loaded
2. **IDENTIFY** your agent type — if no delegation prompt, you are the **Orchestrator**
3. **LOAD** rules from `./codegen/rules/INDEX.md` — follow the loading matrix exactly
4. **APPLY** rules to every action

**Rule loading by agent type:**

- **ALL agents**: Load shared rules (`subagent-core-rules.md`, `session-management.md`)
- **Orchestrator**: ALSO load `orchestration/delegation-patterns.md`
- **feature-developer**: Load per INDEX.md matrix (tdd, phoenix, elixir-code-generation, workflow, git + conditional testing rules)
- **verification-engineer**: Load `verification-workflow.md`, `testing.md`, `elixir-ci.md`, `git.md` (skip `github-actions.md`)
- **code-reviewer**: Load `code-review.md`, `phoenix.md`, `elixir-code-generation.md`, `testing.md`, `git.md`

## 🚨 Planning vs Implementation Rule Separation

**CRITICAL: NEVER load planning rules during implementation**

❌ **FORBIDDEN during implementation**: `planning.md`, `planning-poc.md`

## 🚨 MANDATORY: Rule Compliance Verification

**All agents must prove rule compliance before claiming completion:**

1. **Document rule loading** - Show actual rule content in your session log
2. **Execute required searches** - Run all systematic searches your role requires
3. **Provide proof** - Session log must contain evidence of compliance
4. **No exceptions** - Claims without proof will be rejected

## 🔧 MCP Tools — Log Failures, Never Stop

MCP tools enhance agent capabilities but are **never** a reason to stop work.

**If any MCP tool fails**: log it in the session log and continue with fallbacks (read files directly, use `mix run` for eval, grep for code patterns). Never report an MCP failure as a blocker.

## Universal Context Files

**ALL agents must read BEFORE any work:**

- `./codegen/PROJECT_CONTEXT.md` - Project architecture, module directory, patterns, pitfalls

Note: No `CONTEXT.md` — work happens directly on main branch, no worktrees.

## Workspace Rules

- Work in current directory only (never `../` or `../../`)
- No worktrees — commit directly to main
- No planning phase — implement from task description directly

## Recipe System

**If the orchestrator provides recipe references in your task prompt, use them.** Recipes contain proven patterns and solutions.

**Example delegation with recipe:**

```
Task: "Add rate limiting to messaging"
HELPFUL RESOURCES: See ./codegen/recipes/rate-limiting.md
```

**Your job**: Follow the recipe pattern provided by the orchestrator. Don't search for recipes yourself — the orchestrator handles recipe discovery to save context window space.

## 📚 Library Usage Rules

**Load library-specific docs before implementing with any external library.**

```bash
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^library_name"
```

## 📊 MANDATORY: Session Logging

**Orchestrator** creates the session log as its SECOND action. **Subagents append** to the same file — they do NOT create separate files.

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md`

**When**: Orchestrator creates on session start. Subagents append their section when delegated to.

**LOG FORMAT**:

```markdown
# Session Log

**Started**: $(date -u)
**Task**: [What is being implemented/verified/reviewed]

## Rules Loaded

- [ ] ./codegen/PROJECT_CONTEXT.md
- [ ] ./codegen/rules/shared/subagent-core-rules.md
- [ ] ./codegen/rules/shared/session-management.md
- [ ] [list all rules loaded per INDEX.md matrix]

## MCP Tool Status

- MCP tools: ✅ Available | ❌ Unavailable (fallback: direct file reads)

## Command Execution Log

<!-- Time test runs: start=$(date +%s); mix test ... 2>&1 | tail -20; echo "Duration: $(($(date +%s) - start))s" -->
<!-- Compilation: mix compile 2>&1 — no output = already compiled = SUCCESS -->

| Time     | Duration | Command            | Status | Notes |
| -------- | -------- | ------------------ | ------ | ----- |
| HH:MM:SS |          | `mix compile 2>&1` | ✅     |       |

## Files Modified

- [ ] [list files created/modified]

## PROJECT_CONTEXT.md Updated

- [ ] Updated before handoff (feature-developer only)

## Delegation Timeline (orchestrator only)

| Time  | Agent             | Task               | Result         |
| ----- | ----------------- | ------------------ | -------------- |
| HH:MM | feature-developer | [task description] | ⏳ IN PROGRESS |

<!-- Result options: ⏳ IN PROGRESS | ✅ Done | ❌ Failed | 🔄 Needs iteration -->
```

## Agent Roles & Workflow

**Standard feature cycle:**

```
feature-developer → verification-engineer → code-reviewer → orchestrator commits
  (implement +         (./codegen/ci.sh)      (quality review)   (/commit → git commit)
   update context)
```

**feature-developer**:

- Implements full feature (backend + tests), follows TDD
- Runs targeted `mix test test/path/to/test.exs 2>&1` to verify own work
- Updates `PROJECT_CONTEXT.md` **before reporting done** (see below)
- Does NOT run full CI — that's verification-engineer's job

**verification-engineer**:

- Runs `./codegen/ci.sh` (compile + credo + full test suite)
- For infrastructure/runtime changes: also manually verify runtime behavior — see `PROJECT_CONTEXT.md` for platform-specific commands
- Reports ALL failures — never fixes code

**code-reviewer**:

- Reviews for quality, patterns, architecture
- Reads updated `PROJECT_CONTEXT.md` to understand new additions
- Reports issues directly in session log for orchestrator to delegate fixes

**orchestrator (after "✅ QUALITY APPROVED")**:

- Use `Skill("commit")` — generates the commit message and commits automatically
- No confirmation needed — hybrid mode assumes automated commit after all gates pass

## 🔄 MANDATORY: Update PROJECT_CONTEXT.md Before Handoff

**feature-developer MUST update `./codegen/PROJECT_CONTEXT.md` before reporting done:**

- New modules/files → add to Module Directory
- Changed patterns/conventions → update relevant section
- New pitfalls discovered → add to Common Pitfalls
- New config keys → update Environment Configuration

**Why before handoff**: verification-engineer and code-reviewer both read PROJECT_CONTEXT.md.
Stale context = wrong decisions downstream.

**This is not optional.** PROJECT_CONTEXT.md is the single source of truth for all agents.

## CI Setup

**`./codegen/ci.sh`** runs `make ci` which executes:

1. `MIX_ENV=test mix compile` — pre-warm compilation
2. `mix ci` — full suite:
   - `deps.unlock --check-unused`
   - `deps.audit` + `hex.audit`
   - `sobelow --config .sobelow-conf`
   - `format --check-formatted` + `cmd npx prettier -c .`
   - `credo --strict`
   - `dialyzer`
   - `mix test --cover --warnings-as-errors`
3. `MIX_ENV=test mix ecto.rollback --all --quiet` — DB cleanup

## Universal Requirements

- **Read PROJECT_CONTEXT.md first** - Always, before any work
- **Issue Discovery → Immediate Fixing** - Find issues, fix them — never stop after just documenting
- **Session logging** - Orchestrator creates, subagents append
- **Update PROJECT_CONTEXT.md before done** - feature-developer must update before handing off
