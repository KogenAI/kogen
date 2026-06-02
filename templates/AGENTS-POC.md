# AGENTS.md - PoC WORKSPACE

**IN PoC WORKSPACE** — validation-focused, not production dev.

## MANDATORY: Load Rules FIRST

**On EVERY session start, including greetings like "Hi":**

1. **IDENTIFY** agent type — if no delegation prompt, you are **Orchestrator**
2. **LOAD** PoC rules from `./codegen/rules/INDEX.md`:
   - **All agents**: Load shared rules (subagent-core-rules.md, session-management.md)
   - **Orchestrator**: ALSO load orchestration rules (delegation-patterns.md)
   - **poc-developer**: Load subagents/phoenix.md, subagents/elixir-code-generation.md, subagents/workflow.md, subagents/testing.md, subagents/git-commit-flow.md
   - **dev-gate.sh (PoC mode)**: Load subagents/testing-poc.md, shared/git-read-only.md
   - **reviewer-phoenix (PoC)**: Load subagents/phoenix.md, subagents/elixir-code-generation.md, subagents/testing.md, shared/subagent-core-rules.md (covers git read-only)
3. **APPLY** validation-focused patterns

When orchestrator delegates to reviewer-phoenix for PoC work, delegation prompt MUST specify PoC context:

```
"CRITICAL RULES CONTEXT: PoC code review - apply code-review-poc.md + testing-poc.md patterns"
```

PoC verification: dev-gate.sh hook fires automatically on developer SubagentStop and appends verdict (`ALL CLEAR ✅` / `FAILED ❌` / `INCONCLUSIVE ⚠️ <suffix>`) to the active step log.

## Output Style

Output: caveman ultra. Agents read you, not humans. No preamble. No recap. No pleasantries. Drop articles, filler, hedging. Fragments OK. Arrows for causality (X → Y). Short synonyms (fix not "implement a solution"). Inline acronyms (dev, VE, impl, DB, conn, fn, reqs). NEVER touch JSON schemas, Ecto field names, contracts, code blocks, error strings, "MUST"/"NEVER"/"FORBIDDEN", or hook markers (ALL CLEAR ✅, FAILED ❌, INCONCLUSIVE ⚠️) — verbatim regardless of style. Drop ultra for security warnings or irreversible-action confirmations.

## Planning vs Implementation Rule Separation

FORBIDDEN during implementation: `planning.md` (planning sessions only).

Use ONLY during `ocg bird-eye`, `ocg plan`, `/plan-poc`.

## Rule Compliance Verification

All subagents must prove compliance before done:

1. Document rule loading — show actual rule content in session log
2. Execute required searches
3. Provide proof — session log must contain evidence
4. No exceptions

## Universal Context Files

**ALL agents read BEFORE any work:**

- `./codegen/PROJECT_CONTEXT.md` — architecture and patterns
- `./codegen/plans/poc/overview.md` — PoC validation goals

No `CONTEXT.md` in PoC — work happens directly on main, not in worktrees.

## PoC-Specific Patterns

### Infrastructure Constraints

- **NO persistent storage** — ETS for temporary session data
- **NO authentication** — skip unless core to concept validation
- **NO comprehensive testing** — basic smoke tests only
- **NO production deployment** — simple single-instance
- **NO complex CI/CD** — basic verification only

### Validation Focus

- **YES external tool integration** — `System.cmd()` for Python, APIs, etc.
- **YES real-time updates** — LiveView for processing feedback
- **YES validation metrics** — build in assumption testing
- **YES rapid iteration** — fast feedback over polish

### Agent Roles

**Orchestrator:**

- PoC-focused delegation — PoC context in all reviewer-phoenix delegations
- Basic validation: "Does this prove/disprove assumptions?"
- Fast iteration through validation cycles

**poc-developer:**

- Focused impl: single validation goal per task
- External integrations: Python libs, APIs, CLI tools via `System.cmd()`
- LiveView interfaces for real-time feedback
- Basic smoke tests only

**dev-gate.sh hook (PoC mode):**

- Deterministic gate selection via `lib/gate-select.sh` (CI / phoenix gates)
- Verdict appended to step log: `ALL CLEAR ✅`, `FAILED ❌`, or `INCONCLUSIVE ⚠️ <classification>`
- INCONCLUSIVE classifications: seed-missing, pool-exhaustion, partial-gate, timeout-exceeded, previous-gate-running, concurrent-launch

**reviewer-phoenix (PoC):**

- Validation readiness review
- Anti-pattern detection: over-engineering (DB schemas) and under-engineering (mocked integrations)
- PoC pattern compliance: ETS storage, `System.cmd()` integration, LiveView feedback

## Workspace Rules

- Work in current directory only (never `../`)
- PoC timeline: 2-4 weeks maximum

## Work Context Management

Use RELATIVE paths. NEVER absolute.

```bash
# ✅ CORRECT
./codegen/context/PENDING-*.md

# ❌ WRONG
/Users/.../project/codegen/context/PENDING-*.md
```

- Location: `./codegen/context/`
- Prefixes: `PENDING-*`, `ACTIVE-*`, `RESOLVED-*`
- Check at session start: `ls ./codegen/context/PENDING-* 2>/dev/null`

## Library Usage Rules

**Location**: `$OCG_CONTEXT_DIR/usage_rules/`

```bash
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^library_name"
```

Load when integrating external libraries. Generate if missing: `ocg usage-rules`.

## Session Logging

All agents create session logs.

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<slug>_session.md`
(See `shared/rules/_core/session-log.md` for canonical schema.)

**Agent roles**: `orchestrator`, `poc-developer`, `reviewer-phoenix`

Create as SECOND action (after loading rules). Update continuously.

```markdown
# PoC Session Log: <agent_role>

**Started**: $(date -u)
**PoC Goal**: [Which assumptions are we validating?]

## Rules Loaded

- [ ] ./codegen/PROJECT_CONTEXT.md
- [ ] ./codegen/plans/poc/overview.md
- [ ] ./codegen/rules/shared/git-readonly.md
- [ ] ./codegen/rules/\_core/session-log.md
- [ ] ./codegen/rules/roles/orchestrator.md (PoC orchestrator only)
- [ ] ./codegen/rules/subagents/testing-poc.md (consumed by dev-gate.sh hook classifications)
- [ ] ./codegen/rules/stacks/phoenix/\_core.md (poc-developer, reviewer-phoenix)
- [ ] ./codegen/rules/stacks/phoenix/developer.md (poc-developer)
- [ ] ./codegen/rules/roles/developer.md (poc-developer)
- [ ] ./codegen/rules/stacks/phoenix/testing.md (poc-developer, reviewer-phoenix — covers CI, TDD, backend patterns)
- [ ] ./codegen/rules/roles/committer.md (poc-developer)

## Validation Focus

- [ ] Assumption being tested: [specific assumption]
- [ ] Success criteria: [how we know if it works]
- [ ] Timeline: [rapid iteration target]

## Library Usage Rules Loaded

- [ ] None (if only using built-in modules)
- [ ] [list any loaded]

## Command Execution Log

| Time     | Duration | Command            | Status | Notes |
| -------- | -------- | ------------------ | ------ | ----- |
| HH:MM:SS | Xs       | `mix compile 2>&1` | ✅     |       |

## Files Modified

- [ ] [list files created/modified]

## Delegation Timeline (orchestrator only)

| Time  | Agent         | Task               | Log File                         | Result         |
| ----- | ------------- | ------------------ | -------------------------------- | -------------- |
| HH:MM | poc-developer | [task description] | YYYYMMDD_HHMMSS_poc-developer.md | ⏳ IN PROGRESS |

## Validation Results

- [ ] Assumption validated: [yes/no/partially]
- [ ] Next iteration needed: [what to test next]

## PoC Lessons Learned (for CONTEXT.md)

### ✅ PoC Success Patterns

- [approach]: [why it worked]

### ❌ PoC Time Wasters

- [approach]: [why it was slow, avoid next time]
```

## PoC Orchestration Pattern

1. **Impl**: Delegate to poc-developer for focused validation impl
2. **PoC Verification**: dev-gate.sh SubagentStop hook fires automatically; orchestrator reads verdict from step log
3. **PoC Code Review**: Delegate to reviewer-phoenix with PoC context
4. **Rapid iteration**: Move to next assumption quickly

```
# Impl
Task("Implement YouTube transcript PoC",
     prompt="Build minimal YouTube transcript extraction with real-time feedback...",
     subagent_type="poc-developer")

# PoC Verification — automatic via dev-gate.sh hook (no Task() call).
# After poc-developer SubagentStop, hook appends `ALL CLEAR ✅` / `FAILED ❌` /
# `INCONCLUSIVE ⚠️ <classification>` to the active step log.

# PoC Code Review
Task("Review PoC validation readiness",
     prompt="CRITICAL RULES CONTEXT: PoC code review - apply code-review-poc.md patterns.

             Ensure impl supports assumption testing without over-engineering...",
     subagent_type="reviewer-phoenix")
```

Focus questions:

- "Does this prove our assumption?"
- "Can users complete the core workflow?"
- "Are we getting meaningful validation data?"
- "What's the next assumption to test?"

## MANDATORY: Keep PROJECT_CONTEXT.md Up To Date

After ANY code change:

- New modules/files → add to Module Directory
- Changed patterns → update relevant section
- New pitfalls → add to Common Pitfalls
- Schema changes → update DB Schema
- New env vars → update Environment Configuration

## Universal PoC Requirements

- **Read PROJECT_CONTEXT.md first** — always, before any work
- **Update PROJECT_CONTEXT.md after changes**
- **Validation focus** — every task tests a specific assumption
- **Rapid iteration** — 2-4 week max timeline
- **Minimal infrastructure** — avoid production complexity
- **External integrations** — use existing tools via `System.cmd()`
- **Real-time feedback** — LiveView for user interaction
- **Basic validation** — smoke tests, not comprehensive testing
- **Session logging** — ALL agents must log, create as second action
- **Issue Discovery → Immediate Fixing** — find issues, fix them — never stop after documenting
