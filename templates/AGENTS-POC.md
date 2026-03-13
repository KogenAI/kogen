# AGENTS.md - PoC WORKSPACE

🎯 **YOU ARE IN A PoC WORKSPACE** - This is validation-focused development, not production development.

PoC-focused guidance for AI agents - optimized for rapid validation over production-ready features.

## ⚠️ MANDATORY: Load Rules FIRST

**CRITICAL - On EVERY session start, including greetings like "Hi":**

1. **STOP** - Do NOT respond to the user until rules are loaded
2. **IDENTIFY** your agent type — if no delegation prompt, you are the **Orchestrator** (direct Claude Code session)
3. **LOAD** PoC rules from `./codegen/rules/INDEX.md`:
   - **ALL agents**: Load shared rules (subagent-core-rules.md, session-management.md)
   - **Orchestrator** (default for direct Claude Code sessions): ALSO load orchestration rules (delegation-patterns-poc.md)
   - **poc-developer**: Load subagents/poc-development.md, subagents/poc-success-criteria.md, subagents/phoenix.md, subagents/elixir-code-generation.md, subagents/workflow.md, subagents/testing-backend.md, subagents/git.md
   - **verification-engineer (PoC context)**: Load subagents/verification-workflow-poc.md, subagents/testing-poc.md, subagents/poc-success-criteria.md, subagents/git.md
   - **code-reviewer (PoC context)**: Load subagents/code-review-poc.md, subagents/poc-success-criteria.md, subagents/phoenix.md, subagents/elixir-code-generation.md, subagents/testing-backend.md, subagents/git.md
4. **APPLY** validation-focused patterns to every action

**🚨 CRITICAL**: When orchestrator delegates to verification-engineer or code-reviewer for PoC work, the delegation prompt MUST specify PoC context:

- Example: `"CRITICAL RULES CONTEXT: PoC verification - apply verification-workflow-poc.md + testing-poc.md patterns"`

**PoC Rule Priority:**

- `planning-poc.md` **OVERRIDES** all production patterns
- Focus on **validation over features**
- **Minimal infrastructure** over production-ready systems

## 🚨 Planning vs Implementation Rule Separation

**CRITICAL: NEVER load planning rules during implementation**

❌ **FORBIDDEN during implementation**:

- `planning.md` (planning sessions only)
- `planning-poc.md` (PoC planning sessions only)

✅ **Use these rules ONLY during** planning mode contexts (`ocg bird-eye`, `ocg plan`, `/plan-poc`)

## 🚨 MANDATORY: Rule Compliance Verification

**CRITICAL - All agents must prove rule compliance before claiming completion:**

1. **Document rule loading** - Show actual rule content in your session log
2. **Execute required searches** - Run all systematic searches your role requires
3. **Provide proof** - Session log must contain evidence of compliance
4. **No exceptions** - Claims without proof will be rejected

## Universal Context Files

**ALL agents must read BEFORE any work:**

- `./codegen/PROJECT_CONTEXT.md` - Project architecture and patterns
- `./codegen/plans/poc/overview.md` - PoC validation goals

Note: No `CONTEXT.md` in PoC — work happens directly on main, not in worktrees.

## 🎯 PoC-Specific Patterns

**CRITICAL - Apply these patterns consistently:**

### Infrastructure Constraints

- **NO persistent storage** - Use ETS for temporary session data
- **NO authentication** - Skip unless core to concept validation
- **NO comprehensive testing** - Basic smoke tests and validation only
- **NO production deployment** - Simple single-instance deployment
- **NO complex CI/CD** - Basic verification only

### Validation Focus

- **YES external tool integration** - Use System.cmd() for Python, APIs, etc.
- **YES real-time updates** - LiveView for processing feedback
- **YES validation metrics** - Build in assumption testing
- **YES rapid iteration** - Fast feedback cycles over polish

### Agent Roles

**Orchestrator (Main Agent)**:

- **PoC-focused delegation**: Use PoC context in all delegations to verification-engineer and code-reviewer
- **Validation cycles**: Implementation → PoC verification → PoC code review → iteration
- **Basic validation**: "Does this prove/disprove our assumptions?"
- **Fast iteration**: Move quickly through validation cycles

**poc-developer (Subagent)**:

- **Focused implementation**: Single validation goal per task
- **External integrations**: Python libraries, APIs, CLI tools via System.cmd()
- **LiveView interfaces**: Real-time user feedback and processing updates
- **Basic testing**: Smoke tests to ensure core workflow functions

**verification-engineer (PoC context)**:

- **Real user scenario testing**: Test actual workflows with real data, not just automated tests
- **Basic system health**: Compilation, smoke tests, external integration verification
- **Validation readiness**: Can users test core assumptions through the interface?

**code-reviewer (PoC context)**:

- **Validation readiness review**: Can implementation support assumption testing?
- **Anti-pattern detection**: Prevent over-engineering (database schemas) and under-engineering (mocked integrations)
- **PoC pattern compliance**: ETS storage, System.cmd() integration, LiveView feedback

## Workspace Rules

**OCG PoC Workspace:**

- Work in current directory only (never `../` or `../../`)
- **PoC timeline**: 2-4 weeks maximum for any validation

## Work Context Management (Agent-to-Agent Communication)

**🚨 CRITICAL: ALWAYS use RELATIVE paths for context files!**

```bash
# ✅ CORRECT - relative paths (works in any workspace)
./codegen/context/PENDING-*.md
./codegen/context/RESOLVED-*.md

# ❌ WRONG - absolute paths (writes to wrong location!)
/Users/.../project/codegen/context/PENDING-*.md
```

**Quick reference**:

- Location: `./codegen/context/` (RELATIVE PATH!)
- Prefixes: `PENDING-*`, `ACTIVE-*`, `RESOLVED-*`
- Check at session start: `ls ./codegen/context/PENDING-* 2>/dev/null`

## 📚 Library Usage Rules

**IMPORTANT**: When working with external Elixir libraries, load library-specific usage documentation to ensure correct implementation patterns.

**Usage rules location**: `$OCG_CONTEXT_DIR/usage_rules/` (typically `~/Areas/Optimum/context/usage_rules/`)

**Discovery pattern:**

```bash
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^library_name"
# e.g.
ls $OCG_CONTEXT_DIR/usage_rules/ | grep -i "^jason"    # jason-1.4.4.md
```

**Load when integrating external libraries** — Jason, HTTPoison/Finch, Phoenix LiveView, any unfamiliar library.

**Generate if missing:**

```bash
ocg usage-rules
```

## 📊 MANDATORY: Session Logging

**ALL agents** must create session logs.

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<agent_role>.md`

**Agent roles**: `orchestrator`, `poc-developer`, `verification-engineer`, `code-reviewer`

**When**: Create as SECOND action (after loading rules). Update continuously, not at the end.

**LOG FORMAT**:

```markdown
# PoC Session Log: <agent_role>

**Started**: $(date -u)
**PoC Goal**: [Which assumptions are we validating?]

## Rules Loaded

- [ ] ./codegen/PROJECT_CONTEXT.md
- [ ] ./codegen/plans/poc/overview.md
- [ ] ./codegen/rules/shared/subagent-core-rules.md
- [ ] ./codegen/rules/shared/session-management.md
- [ ] ./codegen/rules/orchestration/delegation-patterns-poc.md (PoC orchestrator only)
- [ ] ./codegen/rules/subagents/poc-development.md (poc-developer only)
- [ ] ./codegen/rules/subagents/poc-success-criteria.md (poc-developer, verification-engineer, code-reviewer)
- [ ] ./codegen/rules/subagents/verification-workflow-poc.md (verification-engineer only)
- [ ] ./codegen/rules/subagents/code-review-poc.md (code-reviewer only)
- [ ] ./codegen/rules/subagents/testing-poc.md (verification-engineer only)
- [ ] ./codegen/rules/subagents/phoenix.md (poc-developer, code-reviewer)
- [ ] ./codegen/rules/subagents/elixir-code-generation.md (poc-developer, code-reviewer)
- [ ] ./codegen/rules/subagents/workflow.md (poc-developer)
- [ ] ./codegen/rules/subagents/testing-backend.md (poc-developer, code-reviewer)
- [ ] ./codegen/rules/subagents/git.md (all subagents)

## Validation Focus

- [ ] Assumption being tested: [specific assumption]
- [ ] Success criteria: [how we know if it works]
- [ ] Timeline: [rapid iteration target]

## Library Usage Rules Loaded

- [ ] None (if only using built-in modules)
- [ ] [list any loaded]

## Command Execution Log

<!-- Time test runs to identify slow suites: start=$(date +%s); mix test ... 2>&1 | tail -20; echo "Duration: $(($(date +%s) - start))s" -->
<!-- Compilation: mix compile 2>&1 — no output = already compiled = SUCCESS -->

| Time     | Duration | Command            | Status | Notes |
| -------- | -------- | ------------------ | ------ | ----- |
| HH:MM:SS | Xs       | `mix compile 2>&1` | ✅     |       |

## Files Modified

- [ ] [list files created/modified]

## Delegation Timeline (orchestrator only)

| Time  | Agent         | Task               | Log File                         | Result         |
| ----- | ------------- | ------------------ | -------------------------------- | -------------- |
| HH:MM | poc-developer | [task description] | YYYYMMDD_HHMMSS_poc-developer.md | ⏳ IN PROGRESS |

<!-- Update each row when agent completes. Add new row for each delegation. -->
<!-- Result options: ⏳ IN PROGRESS | ✅ Done | ❌ Failed | 🔄 Needs iteration -->

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

**PoC Orchestrator Workflow:**

1. **Implementation**: Delegate to poc-developer for focused validation implementation
2. **PoC Verification**: Delegate to verification-engineer with PoC context for real user scenario testing
3. **PoC Code Review**: Delegate to code-reviewer with PoC context for validation readiness review
4. **Rapid iteration**: Move to next assumption validation quickly

**PoC Delegation Examples:**

```
# Implementation
Task("Implement YouTube transcript PoC",
     prompt="Build minimal YouTube transcript extraction with real-time feedback...",
     subagent_type="poc-developer")

# PoC Verification
Task("Verify PoC validation readiness",
     prompt="CRITICAL RULES CONTEXT: PoC verification - apply verification-workflow-poc.md + testing-poc.md patterns.

             Test real user scenario with actual YouTube URL. Verify external integrations work...",
     subagent_type="verification-engineer")

# PoC Code Review
Task("Review PoC validation readiness",
     prompt="CRITICAL RULES CONTEXT: PoC code review - apply code-review-poc.md patterns.

             Ensure implementation supports assumption testing without over-engineering...",
     subagent_type="code-reviewer")
```

**Focus Questions:**

- "Does this prove our assumption?"
- "Can users complete the core workflow?"
- "Are we getting meaningful validation data?"
- "What's the next assumption to test?"

## 🔄 MANDATORY: Keep PROJECT_CONTEXT.md Up To Date

**After ANY code change, update `./codegen/PROJECT_CONTEXT.md`:**

- New modules/files → add to Module Directory
- Changed patterns/conventions → update relevant section
- New pitfalls discovered → add to Common Pitfalls
- Schema changes → update Database Schema
- New env vars or config → update Environment Configuration
- Update `_Last Updated` timestamp at the bottom

**This is not optional.** PROJECT_CONTEXT.md is the single source of truth for AI agents. Stale context causes wrong decisions.

## Universal PoC Requirements

- **Read PROJECT_CONTEXT.md first** - Always, before any work
- **Update PROJECT_CONTEXT.md after changes** - Keep it current
- **Validation focus** - Every task tests a specific assumption
- **Rapid iteration** - 2-4 week maximum timeline
- **Minimal infrastructure** - Avoid production complexity
- **External integrations** - Use existing tools via System.cmd()
- **Real-time feedback** - LiveView for user interaction
- **Basic validation** - Smoke tests, not comprehensive testing
- **Session logging** - ALL agents must log, create as second action
- **Issue Discovery → Immediate Fixing** - Find issues, fix them — never stop after just documenting
