# AGENTS.md

PoC-focused guidance for AI assistants - optimized for rapid validation over production-ready features.

## ⚠️ MANDATORY: Load PoC Rules FIRST

**CRITICAL - BEFORE taking ANY action:**

1. **STOP** - Do NOT proceed without loading PoC-specific rules
2. **IDENTIFY** your agent type: orchestrator or poc-developer
3. **LOAD** PoC rules from `./codegen/rules/INDEX.md`:
   - **ALL agents**: Load `planning-poc.md` for PoC-specific patterns
   - **Orchestrator**: ALSO load `orchestration/delegation-patterns.md` (simplified for PoCs)
   - **poc-developer**: ALSO load `subagents/poc-development.md` and `subagents/phoenix.md`
4. **APPLY** validation-focused patterns to every action

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

- **Simple delegation**: Orchestrator → poc-developer → Orchestrator
- **No complex cycles**: Skip code-reviewer, verification-engineer complexity
- **Basic validation**: "Does this prove/disprove our assumptions?"
- **Fast iteration**: Move quickly through validation cycles

**poc-developer (Subagent)**:

- **Focused implementation**: Single validation goal per task
- **External integrations**: Python libraries, APIs, CLI tools via System.cmd()
- **LiveView interfaces**: Real-time user feedback and processing updates
- **Basic testing**: Smoke tests to ensure core workflow functions

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

**Agent roles**: `orchestrator`, `poc-developer`

**LOG FORMAT**:

```markdown
# PoC Session Log: <agent_role>

**Started**: $(date -u)
**PoC Goal**: [Which assumptions are we validating?]

## PoC Rules Loaded

- [ ] ./codegen/rules/planning-poc.md
- [ ] ./codegen/rules/subagents/poc-development.md (poc-developer only)
- [ ] ./codegen/rules/subagents/phoenix.md (poc-developer only)

## Validation Focus

- [ ] Assumption being tested: [specific assumption]
- [ ] Success criteria: [how we know if it works]
- [ ] Timeline: [rapid iteration target]

## Files Modified

- [ ] [list files created/modified for this validation]

## Delegation (orchestrator only)

- [x] Delegating to poc-developer: "[specific validation task]" → IN PROGRESS
- [x] Delegated to poc-developer: → COMPLETED/BLOCKED

## Validation Results

- [x] Assumption validated: [yes/no/partially]
- [ ] Next iteration needed: [what to test next]
```

## Simplified Orchestration

**PoC Orchestrator Pattern:**

1. **Break down validation** into focused poc-developer tasks
2. **Delegate single assumptions** - one validation goal per task
3. **Quick validation** - basic smoke test, not comprehensive CI
4. **Rapid iteration** - move to next assumption quickly

**No Complex Cycles:**

- ❌ Orchestrator → poc-developer → code-reviewer → verification-engineer
- ✅ Orchestrator → poc-developer → Orchestrator (validate assumption)

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
