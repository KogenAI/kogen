# AGENTS.md - PoC WORKSPACE

🎯 **YOU ARE IN A PoC WORKSPACE** - This is validation-focused development, not production development.

PoC-focused guidance for AI agents - optimized for rapid validation over production-ready features.

## ⚠️ MANDATORY: Load PoC Rules FIRST

**CRITICAL - BEFORE taking ANY action:**

1. **STOP** - Do NOT proceed without loading PoC-specific rules
2. **IDENTIFY** your agent type from the delegation prompt
3. **LOAD** PoC rules from `./codegen/rules/INDEX.md`:
   - **ALL agents**: Load shared rules (server-management.md, subagent-core-rules.md)
   - **Orchestrator (PoC mode)**: ALSO load orchestration rules (delegation-patterns-poc.md for PoC delegation)
   - **poc-developer**: Load subagents/poc-development.md, subagents/phoenix.md, subagents/elixir-code-generation.md, subagents/git.md
   - **verification-engineer (PoC context)**: Load subagents/verification-workflow-poc.md, subagents/testing-poc.md, subagents/git.md
   - **code-reviewer (PoC context)**: Load subagents/code-review-poc.md, subagents/phoenix.md, subagents/elixir-code-generation.md, subagents/git.md
4. **APPLY** validation-focused patterns to every action

**🚨 CRITICAL**: When orchestrator delegates to verification-engineer or code-reviewer for PoC work, the delegation prompt MUST specify PoC context:

- Example: `"CRITICAL RULES CONTEXT: PoC verification - apply verification-workflow-poc.md + testing-poc.md patterns"`

**PoC Rule Priority:**

- `planning-poc.md` **OVERRIDES** all production patterns
- Focus on **validation over features**
- **Minimal infrastructure** over production-ready systems

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

## 🚨 SIMPLIFIED: Rule Compliance

**PoC agents must prove they're following PoC patterns:**

1. **Document PoC rule loading** - Show planning-poc.md content in session log
2. **Validate assumptions** - Every task should test a specific assumption
3. **Avoid production patterns** - No comprehensive testing, CI, auth, persistence
4. **Focus on validation** - "Does this prove the concept works?"

## Workspace Rules

**OCG PoC Workspace:**

- Work in current directory only
- Check `./codegen/CONTEXT.md` for ports/settings
- **PoC timeline**: 2-4 weeks maximum for any validation

## Universal Context Files

**ALL PoC agents must read**:

- `./codegen/PROJECT_CONTEXT.md` - Project architecture
- `./codegen/CONTEXT.md` - Workspace state, ports, progress
- `./codegen/plans/poc/overview.md` - PoC validation goals

## 📊 SIMPLIFIED: Session Logging

**PoC agents log for debugging:**

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<agent_role>.md`

**Agent roles**: `orchestrator`, `poc-developer`, `verification-engineer`, `code-reviewer`

**LOG FORMAT**:

```markdown
# PoC Session Log: <agent_role>

**Started**: $(date -u)
**PoC Goal**: [Which assumptions are we validating?]

## PoC Rules Loaded

- [ ] ./codegen/rules/shared/server-management.md
- [ ] ./codegen/rules/shared/subagent-core-rules.md
- [ ] ./codegen/rules/orchestration/delegation-patterns-poc.md (PoC orchestrator only)
- [ ] ./codegen/rules/subagents/poc-development.md (poc-developer only)
- [ ] ./codegen/rules/subagents/verification-workflow-poc.md (verification-engineer only)
- [ ] ./codegen/rules/subagents/code-review-poc.md (code-reviewer only)
- [ ] ./codegen/rules/subagents/testing-poc.md (verification-engineer only)
- [ ] ./codegen/rules/subagents/phoenix.md (poc-developer, code-reviewer)
- [ ] ./codegen/rules/subagents/elixir-code-generation.md (poc-developer, code-reviewer)
- [ ] ./codegen/rules/subagents/git.md (all subagents)

## Validation Focus

- [ ] Assumption being tested: [specific assumption]
- [ ] Success criteria: [how we know if it works]
- [ ] Timeline: [rapid iteration target]

## Command Execution Log

**CRITICAL: Log EVERY command with timestamp and duration to debug PoC performance issues**

| Time     | Duration | Command                      | Status | Notes                                 |
| -------- | -------- | ---------------------------- | ------ | ------------------------------------- |
| 15:20:15 | 1.8s     | `mix compile`                | ✅     | Quick compilation                     |
| 15:20:17 | 25.3s    | Test YouTube URL workflow    | ✅     | Real user scenario - slow but working |
| 15:20:45 | 0.5s     | `mix test --only smoke_test` | ✅     | Basic smoke tests                     |

**PoC Performance Tracking:**

- ✅ **Fast commands** (<5s): Basic compilation, smoke tests
- ⚠️ **Acceptable PoC delays** (5-30s): Real external API calls, transcript extraction
- ❌ **PoC blockers** (>30s): Investigate why - should be rapid validation

**Success Patterns for PoC:**

- Use real data but cache when possible for iteration speed
- Focus on end-to-end workflow validation over comprehensive testing
- External integration delays are expected but should be <30s per call

## Files Modified

- [ ] [list files created/modified for this validation]

## Delegation (orchestrator only)

- [x] Delegating to poc-developer: "[specific validation task]" → IN PROGRESS
- [x] Delegated to poc-developer: → COMPLETED/BLOCKED

## Validation Results

- [x] Assumption validated: [yes/no/partially]
- [ ] Next iteration needed: [what to test next]

## PoC Lessons Learned (for CONTEXT.md)

**CRITICAL: Document PoC-specific lessons to accelerate future validation cycles**

### ✅ PoC Success Patterns

- [Fast validation approach]: [Why this worked for rapid testing]
- [Effective external integration]: [How to use this tool/API efficiently]

### ❌ PoC Time Wasters

- [Slow validation approach]: [Why this took too long, avoid next time]
- [Problematic external tool]: [What caused delays, alternatives to try]

### 🔄 PoC Optimization for Next Time

- [Efficient command sequence for this type of validation]
- [External tools/approaches that work well for PoC speed]
- [Performance shortcuts discovered for rapid iteration]

**SAVE TO CONTEXT.md**: Update `./codegen/CONTEXT.md` with PoC-specific lessons to improve validation speed.
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

## Work Context Management

**Simplified for PoCs:**

```bash
# Check for validation work
ls ./codegen/context/PENDING-* 2>/dev/null || echo "No pending validations"

# Create validation context
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
cat > ./codegen/context/PENDING-validation-${TIMESTAMP}.md << 'EOF'
# PoC Validation Task
**Assumption**: [specific assumption to test]
**Success Criteria**: [how we know it works]
**Timeline**: [rapid iteration target]
EOF
```

## Universal PoC Requirements

- **Validation focus** - Every task tests a specific assumption
- **Rapid iteration** - 2-4 week maximum timeline
- **Minimal infrastructure** - Avoid production complexity
- **External integrations** - Use existing tools via System.cmd()
- **Real-time feedback** - LiveView for user interaction
- **Basic validation** - Smoke tests, not comprehensive testing
- **Session logging** - Track assumption validation progress
