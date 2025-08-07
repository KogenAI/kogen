# AGENTS.md

Universal guidance for AI assistants in OCG workspaces.

## ⚠️ MANDATORY: Load Your Rules FIRST

**CRITICAL - BEFORE taking ANY action:**

1. **STOP** - Do NOT proceed without loading rules
2. **IDENTIFY** your agent type from your prompt/role
3. **LOAD** appropriate rules from `/codegen/rules/INDEX.md`:
   - **ALL agents**: Load shared rules for universal knowledge
   - **Main/Orchestrator**: ALSO load ALL orchestration rules
   - **Specialized Subagents**: ALSO load your domain-specific rules
4. **APPLY** these rules to every action you take

**Examples by Agent Type:**

**Main Agent (Orchestrator):**

- MUST load: `orchestration/parallel-testing.md` for handling test failures efficiently
- MUST load: `orchestration/task-based-delegation.md` for proper work decomposition
- MUST load: `orchestration/bottleneck-patterns.md` for identifying blocking tasks
- MUST load: ALL shared rules for server management, workspace isolation

**Feature Developer:**

- MUST load: `phoenix.md`, `elixir-code-generation.md` for implementation standards
- MUST load: Shared rules for workspace management
- SKIP: Testing rules (delegate to qa-engineer)

**QA Engineer:**

- MUST load: `testing.md`, `wallaby.md`, `ci-pipeline.md` for test strategies
- MUST load: `feature-tests.md` for writing comprehensive test suites
- MUST load: Shared rules for CI/CD awareness

**UI Specialist:**

- MUST load: `ui-implementation.md`, `tailwind.md` for styling patterns
- MUST load: `figma.md` when working with designs
- MUST load: Shared rules for workspace management

**❌ NEVER:**

- Skip directly to implementation without loading rules
- Assume you know patterns without checking rules
- Ignore rule updates or improvements

**✅ ALWAYS:**

- Load rules as your FIRST action
- Re-check rules when switching tasks
- Apply rules consistently throughout your work

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

## Rule Loading (Detailed)

**⚠️ TIMING: Load rules IMMEDIATELY upon session start - BEFORE any other action!**

**See `./codegen/rules/INDEX.md`** for the complete index of rules and loading strategy.

**WHEN to load rules:**

1. **Session Start** - FIRST action, no exceptions
2. **Task Switch** - When changing focus areas
3. **Error Recovery** - When encountering unexpected patterns
4. **Delegation** - Before passing work to subagents

**WHAT to load:**

- **Shared rules** - Universal knowledge (server management, workspace isolation, etc.) - ALL agents
- **Your domain rules** - Specific to your agent type and expertise - MANDATORY for your role
- **Task-specific rules** - Additional rules as needed for current work
- **Orchestration rules** - ALL of them if you're the main agent

**HOW to verify:**

- Check you've loaded all required rules for your agent type
- Confirm rules match your current task
- Re-read rules if you encounter patterns not covered in your initial load

## 📊 MANDATORY: Session Logging

**CRITICAL - Log your session for debugging the OCG system:**

**WHEN**:

1. Create log file as your SECOND action (after loading rules)
2. **UPDATE CONTINUOUSLY** - Edit the log file throughout your session
3. Update after each major action (delegation, tool use, file modification)

**WHERE**: `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_<agent_role>.md`

**Agent roles**: `orchestrator`, `feature-developer`, `qa-engineer`, `ui-specialist`, `devops-manager`, `translator`, `manual-tester`

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
- [x] Delegated to feature-developer: "implement user registration" → COMPLETED
- [x] Delegating to qa-engineer: "verify login flow" → IN PROGRESS
- [x] Delegated to qa-engineer: "verify login flow" → FOUND 3 ISSUES
- [x] Delegating to feature-developer: "fix validation issues X, Y, Z" → IN PROGRESS
- [x] Delegated to feature-developer: "fix validation issues X, Y, Z" → COMPLETED
- [ ] N/A - Not an orchestrator

## Completion Status

- [x] All tasks completed successfully
- [ ] Blocked by: [reason if incomplete]
```

**BASH COMMAND for timestamp**: `date -u +%Y%m%d_%H%M%S`

**WHY**: This helps debug whether OCG rules loading, MCP tool access, and multi-agent coordination are working properly.

## Universal Requirements

- **100% task completion** - Finish all assigned work completely
- **Update step context** - Document progress in `./codegen/context/step-XX.md` files
- **Workspace isolation** - Never navigate outside current directory
- **Port awareness** - Use ports from CONTEXT.md, not hardcoded values
