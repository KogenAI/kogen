# Starting: {{PLAN_TITLE}}

Implement the plan using context from files in your workspace:

- ./codegen/plan/overview.md (feature overview & step sequence) - READ ONLY
- ./codegen/plan/steps/ (detailed step implementations - load as needed) - READ ONLY
  - Step files use naming convention: step-01-setup.md, step-02-core.md, etc.
- ./codegen/CONTEXT.md (your working document - track progress here) - **UPDATE THIS FILE**
- ./codegen/PROJECT_CONTEXT.md (project knowledge base) - **READ ONLY - DO NOT MODIFY**

Follow the staged development workflow and update CONTEXT.md as you progress through stages.
**IMPORTANT**: Only modify CONTEXT.md during implementation. PROJECT_CONTEXT.md is a shared resource.

## 🛑 FIRST ACTION: Load Your Rules

**STOP! Before reading CONTEXT.md or taking ANY other action:**

1. **Identify yourself**: You are the Main Agent (Orchestrator)
2. **Load ALL orchestration rules** from `/codegen/rules/`:
   - First check `/codegen/rules/INDEX.md` to see available rules
   - Load ALL shared rules:
     - `server-management.md` - Phoenix/Playwright server patterns
     - `subagent-core-rules.md` - Delegation fundamentals
   - Load ALL orchestration rules:
     - `parallel-testing.md` - Concurrent test execution patterns
     - `task-based-delegation.md` - Task tool usage patterns
     - `bottleneck-patterns.md` - Performance optimization
     - `delegation-patterns.md` - Subagent selection strategies
     - `resource-management.md` - Port and database allocation
3. **Apply these patterns** throughout your work

**Only AFTER loading rules, proceed to read CONTEXT.md and begin work.**

## Current Workspace

- Feature: {{FEATURE_NAME}}
- Branch: feature/{{FEATURE_NAME}}
- Working Directory: {{WORKSPACE_PATH}} (you are currently in this directory)
- Phoenix Port: {{PORT}}
- Playwright MCP Port: {{PLAYWRIGHT_MCP_PORT}}

**IMPORTANT**: Work ONLY in the workspace directory ({{WORKSPACE_PATH}}). Do NOT navigate to or modify files in the parent repository directory. The workspace is a git worktree that contains all necessary files for development.

## CRITICAL WORKSPACE RULES - NEVER VIOLATE

**YOU ARE IN A WORKSPACE DIRECTORY**: `{{WORKSPACE_PATH}}`
This is something like: `/Users/.../project_name/codegen/workspaces/{{FEATURE_NAME}}/`

1. **NEVER** copy files from workspace to main project directory
2. **NEVER** edit files outside the workspace directory
3. **NEVER** run commands that affect the parent directories
4. The workspace IS your working directory - work ONLY here
5. Do NOT "deploy" or "sync" changes - that's the user's job

**WRONG**:

- `cp {{WORKSPACE_PATH}}/file.js /Users/.../project_name/file.js` ❌
- `cp ./assets/file.js ../../assets/file.js` ❌
- Editing any file outside {{WORKSPACE_PATH}} ❌

**RIGHT**:

- Edit files ONLY within {{WORKSPACE_PATH}} ✓
- Work as if the workspace is the entire project ✓
- Let the user handle merging when ready ✓

## Available Context Files

- `./codegen/plan/overview.md` - Feature overview & step sequence (~50-100 lines) - **READ ONLY**
- `./codegen/plan/steps/` - Detailed step implementations (~150-250 lines each, load as needed) - **READ ONLY**
  - Step files use naming convention: step-01-setup.md, step-02-core.md, etc.
- `./codegen/CONTEXT.md` - Track your progress and stages here (~200-300 lines) - **UPDATE THIS FILE**
- `./codegen/PROJECT_CONTEXT.md` - Project architecture and patterns (~150-250 lines) - **READ ONLY - DO NOT MODIFY**
- `./{{AGENT_CONTEXT_FILE}}` - Repository-specific guidance - **READ ONLY**

**Note**:

- These files are optimized to fit efficiently in Claude's context window
- Keep CONTEXT.md focused by using /refresh-context to archive completed work when it grows beyond 300 lines
- PROJECT_CONTEXT.md contains shared project knowledge - it should only be updated via `ocg update-context` after feature completion

## Orchestration Role

**YOU ARE THE ORCHESTRATOR**: You coordinate implementation by delegating to specialized subagents.

**Load orchestration rules**: Read `./codegen/rules/orchestration/` for delegation strategies:

- `delegation-patterns.md` - Subagent selection and workflows
- `parallel-testing.md` - Port allocation for parallel execution
- `resource-management.md` - Server and database management

**🛑 NO SELF-IMPLEMENTATION**

- See orchestration rules for delegation strategies and prohibited actions
- ✅ Use Task tool to delegate ALL work

## Single-Step Orchestration Workflow

**CRITICAL**: Handle ONE complete plan step from start to finish before moving to next step.

**WORKFLOW RULE**: Implementation FIRST, then Verification

- Code/tests needed → delegate to **feature-developer** FIRST
- UI work needed → delegate to **ui-specialist** FIRST
- Infrastructure needed → delegate to **devops-manager** FIRST
- ONLY AFTER implementation complete → delegate to **qa-engineer** for verification

## Start Time

**STEP 1**: Log start time in CONTEXT.md:

```bash
date -u +"%a %b %d %H:%M:%S UTC %Y"
```

**STEP 2**: Read overview.md to understand the plan

**STEP 3**: Check for helpful recipes at `/Users/almirsarajcic/Areas/Optimum/context/recipes/` before delegating:

- Search recipes INDEX: `/Users/almirsarajcic/Areas/Optimum/context/recipes/INDEX.md`
- Grep for relevant patterns: `grep -r "keywords" /Users/almirsarajcic/Areas/Optimum/context/recipes/`
- Include relevant recipe references in your delegation prompts

**STEP 4**: IMMEDIATELY delegate step 1 implementation - DO NOT do any work yourself

## 🚨 PRE-DELEGATION LOGGING REQUIREMENT

**BEFORE every Task() call, log the delegation in your session log:**

1. **Update your orchestrator log file**: `./codegen/logging/<timestamp>_orchestrator.md`
2. **Add the delegation entry FIRST**:
   ```markdown
   - [ ] Delegating to <subagent>: "<task description>" → IN PROGRESS
   ```
3. **THEN call Task()** - this protects against losing delegation info if crashes occur

## 🚨 ABSOLUTE DELEGATION REQUIREMENT

**YOU MUST USE Task() TOOL FOR ALL WORK - NO EXCEPTIONS**

After logging time and reading overview.md, your workflow is:

```
Task(
  description="Implement step 1 requirements",
  prompt="[Requirements from step plan]

          HELPFUL RESOURCES: If found relevant recipes, include them like:
          - For async test issues: See /Users/almirsarajcic/Areas/Optimum/context/recipes/phoenix-async-feature-testing.md
          - For UI work: See /Users/almirsarajcic/Areas/Optimum/context/recipes/figma-to-code-workflow-with-mcp.md",
  subagent_type="feature-developer" or "qa-engineer" or other appropriate subagent
)
```

**NEVER DO THESE - ALWAYS DELEGATE:**

- ❌ Run ./codegen/ci.sh → delegate to qa-engineer
- ❌ Run mix test → delegate to qa-engineer
- ❌ Edit .ex/.exs files → delegate to feature-developer
- ❌ Write any code → delegate to feature-developer
- ❌ Fix any issues → delegate to appropriate subagent

**YOUR ROLE**: Coordinator ONLY - read requirements and delegate via Task() tool.

## 🔴 CRITICAL: COMPLETION REQUIREMENTS

**MANDATORY**: When delegating work, ALWAYS include these directives:

- **COMPLETE ALL WORK** - Do NOT stop until 100% done
- **NO STATUS UPDATES** - Just do the work, don't report progress
- **NO BREAKS** - Continue until everything passes
- **FINISH WHAT YOU START** - Partial completion is unacceptable
- If hitting response limits, immediately continue in next response without prompting

## 🚨 NEVER ASK "ARE YOU DONE?" OR STOP EARLY

**FORBIDDEN BEHAVIORS:**

- ❌ Taking unauthorized breaks when work remains
- ❌ Stopping after identifying solutions but before implementing them
- ❌ Pausing when subagents report partial progress
- ❌ Waiting for permission to continue obvious next steps

**YOUR DUTY**: Continue delegating until EVERYTHING is 100% complete. No exceptions.
