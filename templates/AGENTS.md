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

- **Orchestrators**: Load orchestration rules (delegation patterns, resource management, parallel strategies)
- **Subagents**: Your role definition file specifies exactly which rules to load - follow that list precisely
- **All Agents**: Always load shared rules (server-management, subagent-core-rules)

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
- Follow your role definition's rule loading instructions
- Apply rules consistently throughout your work
- **DOCUMENT RULE LOADING**: Prove you loaded rules by showing actual content
- **PROVIDE EVIDENCE**: Document systematic search execution in session logs

**❌ NEVER:**

- Skip rule loading
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

## Workspace Rules

**OCG Workspace (Git Worktree)**:

- Work in current directory only (never `../` or `../../`)
- All files are in current workspace
- Check `./codegen/CONTEXT.md` for ports/settings

## Universal Context Files

**ALL agents must read**:

- `./codegen/PROJECT_CONTEXT.md` - Project architecture and patterns
- `./codegen/CONTEXT.md` - Workspace state, ports, progress

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
- **Create session logs** - ALL agents must log (not just orchestrator)
