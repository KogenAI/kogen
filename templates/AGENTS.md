# AGENTS.md

Universal guidance for AI assistants in OCG workspaces.

## ⚠️ MANDATORY: Load Your Rules FIRST

**CRITICAL - BEFORE taking ANY action:**

1. **STOP** - Do NOT proceed without loading rules
2. **IDENTIFY** your agent type from your prompt/role
3. **LOAD** appropriate rules from `./codegen/rules/INDEX.md`:
   - **ALL agents**: Load shared rules for universal knowledge
   - **Main/Orchestrator**: ALSO load ALL orchestration rules
   - **Specialized Subagents**: ALSO load your domain-specific rules from subagents/
4. **APPLY** these rules to every action you take

**Rule Loading Strategy:**

- **Orchestrators**: Load orchestration rules (delegation-patterns.md, resource management, parallel strategies) + conditionally load UI delegation patterns if plan mentions UI/design work
- **Subagents**: Your role definition file specifies exactly which rules to load - follow that list precisely
- **All Agents**: Always load shared rules (server-management, subagent-core-rules)

**🚨 CRITICAL: Cross-Role Rule Contamination**

**PROBLEM**: Implementation rules (like `testing.md`, `workflow.md`, `ci-pipeline.md`) are loaded by multiple agent roles but contain role-specific commands that could mislead other agents.

**SOLUTION - Role-Based Rule Loading Restrictions**:

**NEVER LOAD THESE RULES** unless specified in your role template:

- **`code-review.md`**: ONLY for code-reviewer (systematic searches, git diff analysis)
- **`verification-workflow.md`**: ONLY for verification-engineer (CI execution, comprehensive testing)

**SOLUTION - Command Filtering by Role**:

- **When you load a rule file, ONLY follow commands appropriate for your role**
- **Rule files may contain examples for different roles - ignore commands outside your role**
- **Your role template specifies exactly which rules to load - never deviate from that list**

**Role-Specific Command Restrictions**:

- **verification-engineer**: Can run `./codegen/ci.sh`, `mix test`, individual CI components
- **feature-developer**: Can run `mix test test/path/file.exs`, `mix compile`, `mix format` - NEVER `./codegen/ci.sh`, NEVER load `code-review.md`
- **code-reviewer**: Can run `git diff`, `grep` searches - NEVER `mix test`, NEVER `./codegen/ci.sh`
- **translator**: Can run `mix gettext.extract` - NEVER `./codegen/ci.sh`, NEVER load `code-review.md`
- **test-engineer**: Can run `mix test`, individual test commands - NEVER `./codegen/ci.sh`, NEVER load `verification-workflow.md`

**Example**: If `testing.md` shows `./codegen/ci.sh`, only verification-engineer should execute it. Other agents should treat it as documentation only.

**WHY**: Prevents agents from loading inappropriate rules and running inappropriate commands even when those appear in legitimately-accessible rule files.

**🚨 CRITICAL RULE HIERARCHY:**

- **Each role has context-dependent critical rules** that take precedence over all other guidance
- **Orchestrators**: `delegation-patterns.md` always overrides everything
- **Subagents**: Multiple critical rules depending on task context:
  - **Always critical**: Core domain rules (e.g., `phoenix.md` for feature-developer)
  - **Context critical**: Task-specific rules (e.g., `feature-tests.md` when doing browser tests)
  - **Orchestrator specifies context** in delegation prompts
- **If ANY conflict exists** between critical rules and other sources, the critical rules WIN
- **Follow critical rules exactly** - no exceptions, no shortcuts, no interpretations

**✅ ALWAYS:**

- Load rules as your FIRST action
- **READ COMPLETE FILES**: Use Read tool WITHOUT limit/offset parameters to get full file content
- Follow your role definition's rule loading instructions
- Apply rules consistently throughout your work
- **DOCUMENT RULE LOADING**: Prove you loaded rules by showing actual content
- **PROVIDE EVIDENCE**: Document systematic search execution in session logs

**❌ NEVER:**

- Skip rule loading
- **Use limit/offset parameters when reading rule files** - read complete files only
- Assume you know patterns without checking rules
- Ignore your role definition's required rules
- **Claim completion without proof of rule compliance**
- **Skip systematic searches required by your role**

## 🚨 MANDATORY: Rule Compliance Verification

**CRITICAL - All agents must prove rule compliance before claiming completion:**

1. **Document rule loading** - Show actual rule content in your session log
2. **Execute required searches** - Run all systematic searches your role requires
3. **Provide proof** - Session log must contain evidence of compliance
4. **No exceptions** - Claims without proof will be rejected

**Why**: Prevents agents from ignoring rules and ensures quality standards.

## 🚨 MANDATORY: MCP Tool Failure Protocol

**CRITICAL - All agents load the shared MCP tool failure protocol:**

- **Load**: `./codegen/rules/shared/mcp-tool-failure-protocol.md`
- **Required for**: ui-specialist, feature-developer, verification-engineer
- **Contains**: Immediate tool verification, failure reporting, workflow blocking rules

**RATIONALE**: Working without MCP tools produces broken/incomplete results. Better to fail fast and get tools fixed than waste time on unusable work.

## Workspace Rules

**OCG Workspace (Git Worktree)**:

- Work in current directory only (never `../` or `../../`)
- All files are in current workspace
- Check `./codegen/CONTEXT.md` for ports/settings

## Universal Context Files

**ALL agents must read**:

- `./codegen/PROJECT_CONTEXT.md` - Project architecture and patterns
- `./codegen/CONTEXT.md` - Workspace state, ports, progress

**UI-related agents should also read** (if files exist):

- `./codegen/FIGMA_MAP.md` - Figma node ID to Phoenix component mappings
- `./codegen/FIGMA_DESIGN_SYSTEM_RULES.md` - Figma design system rules and guidelines
- `./codegen/FIGMA_TOKEN_MAPPING.md` - Figma design token mappings

## Recipe System

**IMPORTANT**: If the orchestrator provides recipe references in your task prompt, use them! Recipes contain proven patterns and solutions.

**Example delegation with recipe:**

```
Task: "Fix async test failures"
HELPFUL RESOURCES: See ./codegen/recipes/phoenix-async-feature-testing.md
```

**Your job**: Follow the recipe pattern provided by the orchestrator. Don't search for recipes yourself - the orchestrator handles recipe discovery to save context window space.

## 📊 MANDATORY: Session Logging

**CRITICAL - Log your session for debugging the OCG system:**

**WHEN**:

1. Create log file as your SECOND action (after loading rules)
2. **UPDATE CONTINUOUSLY** - Edit the log file throughout your session
3. Update after each major action (delegation, tool use, file modification)

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<agent_role>.md`

**Agent roles**: `orchestrator`, `feature-developer`, `test-engineer`, `verification-engineer`, `code-reviewer`, `ui-specialist`, `devops-manager`, `translator`

**LOG FORMAT**:

```markdown
# Session Log: <agent_role>

**Started**: $(date -u)
**Task**: [Brief description of main task]

## Rules & Context Loaded

- [ ] ./codegen/rules/INDEX.md
- [ ] ./codegen/PROJECT_CONTEXT.md
- [ ] ./codegen/CONTEXT.md
- [ ] phoenix.md
- [ ] testing.md
- [ ] [list each rule file you actually loaded]

## Recipes Used

- [ ] /path/to/recipe.md (if any were provided by orchestrator)

## MCP Tools Used

**IMPORTANT: Track ACTUAL tool usage, not planned usage. Update this section each time you call an MCP tool.**

- [ ] Figma MCP: get_image (2), get_code (1), get_variable_defs (1) = 4 total calls
- [ ] Playwright MCP: browser_screenshot (3), browser_navigate (2) = 5 total calls
- [ ] Tidewave MCP: project_eval (6), get_source_location (0) = 6 total calls
- [ ] No MCP tools used (if none were actually called)

## Command Execution Log

**CRITICAL: Log EVERY command with timestamp and duration to debug performance issues**

| Time     | Duration | Command                      | Status | Notes                    |
| -------- | -------- | ---------------------------- | ------ | ------------------------ |
| 08:25:30 | 2.1s     | `mix compile`                | ✅     | Clean compilation        |
| 08:25:33 | 0.8s     | `mix test --only smoke_test` | ✅     | All smoke tests pass     |
| 08:25:45 | 12.3s    | `./codegen/ci.sh`            | ❌     | Failed on gettext checks |
| 08:25:47 | 1.2s     | `mix gettext.extract`        | ✅     | Fixed gettext issue      |
| 08:25:49 | 8.9s     | `./codegen/ci.sh`            | ✅     | All checks pass          |

**Track patterns:**

- ✅ **Success patterns**: Commands that work well (reuse these)
- ❌ **Failed commands**: Commands that failed (avoid/fix these)
- ⏱️ **Performance**: Commands taking >30s (investigate why)

## Files Modified

- [ ] src/lib/component.ex (created/updated)
- [ ] test/feature_test.exs (created)
- [ ] [list all files you created/modified]

## Delegation (orchestrator only)

**CRITICAL: Log delegations BEFORE calling Task() to prevent information loss on crashes.**

**WORKFLOW:**

1. **FIRST**: Add delegation entry with "IN PROGRESS" status
2. **THEN**: Call Task() tool
3. **AFTER**: Update status based on subagent results

**Example tracking:**

- [x] Delegating to feature-developer: "implement user registration" → IN PROGRESS
- [x] Delegated to feature-developer: → COMPLETED
- [x] Delegating to verification-engineer: "verify implementation" → IN PROGRESS
- [x] Delegated to verification-engineer: → FOUND 2 ISSUES
- [x] Delegating to feature-developer: "fix issues" → IN PROGRESS
- [x] Delegated to feature-developer: → COMPLETED
- [ ] N/A - Not an orchestrator

## Lessons Learned (for CONTEXT.md)

**CRITICAL: Document what worked/didn't work to avoid repeating mistakes and reuse successful patterns**

### ✅ What Worked Well

- [Command/approach that worked]: [Why it was effective]
- [Successful pattern]: [When to use this again]

### ❌ What Failed/Was Slow

- [Failed command]: [Why it failed, how to avoid]
- [Slow process]: [What caused the delay, alternatives to try]

### 🔄 Recommendations for Next Time

- [Specific command sequence that worked efficiently]
- [Tools/approaches to avoid]
- [Performance optimizations discovered]

**SAVE TO CONTEXT.md**: Update `./codegen/CONTEXT.md` with key lessons from this section to improve future iterations.

## Completion Status

- [x] All tasks completed successfully
- [ ] Blocked by: [reason if incomplete]
```

**BASH COMMAND for timestamp**: `date -u +%Y%m%d_%H%M%S`

**WHY**: This helps debug whether OCG rules loading, MCP tool access, and multi-agent coordination are working properly.

## Work Context Management (Agent-to-Agent Communication)

**All agents use bash commands directly for work contexts:**

### Checking for Work (All Agents at Session Start)

```bash
# Check for pending work
ls ./codegen/context/PENDING-* 2>/dev/null || echo "No PENDING work"

# Check for interrupted work
ls ./codegen/context/ACTIVE-* 2>/dev/null || echo "No ACTIVE work"
```

### Creating Work Contexts (Orchestrator Before Delegating Issues)

```bash
# Create issue context with full details
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
cat > ./codegen/context/PENDING-issues-${TIMESTAMP}-code-review.md << 'EOF'
# Code Review Issues
**Source**: code-reviewer
**Target**: feature-developer
**Status**: PENDING

## Issues Found
[PASTE FULL REVIEW REPORT HERE]
EOF
```

### Managing Work Contexts (Subagents)

```bash
# When starting work on an issue
mv ./codegen/context/PENDING-issues-*.md ./codegen/context/ACTIVE-issues-*.md

# When completing work
mv ./codegen/context/ACTIVE-issues-*.md ./codegen/context/RESOLVED-issues-*.md
```

## Universal Requirements

- **100% task completion** - Finish all assigned work completely
- **Check work contexts** - Always check `./codegen/context/PENDING-*` at session start
- **Update work contexts** - Move through PENDING→ACTIVE→RESOLVED as you work
- **Workspace isolation** - Never navigate outside current directory
- **Port awareness** - Use ports from CONTEXT.md, not hardcoded values
- **Server management** - Phoenix server is already running; only restart if explicitly needed
- **Create session logs** - ALL agents must log (not just orchestrator)
