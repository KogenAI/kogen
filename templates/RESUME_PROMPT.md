# Resuming: {{PLAN_TITLE}}

Continue implementing the plan using context from files in your workspace:

- ./codegen/plan/overview.md (feature overview & step sequence, ~50-100 lines) - READ ONLY
- ./codegen/plan/steps/ (detailed step implementations, ~150-250 lines each, load as needed) - READ ONLY
  - Step files use naming convention: step-01-setup.md, step-02-core.md, etc.
- ./codegen/CONTEXT.md (your working document - check current stage, ~200-300 lines) - **UPDATE THIS FILE**
- ./codegen/PROJECT_CONTEXT.md (project knowledge base, ~150-250 lines) - **READ ONLY - DO NOT MODIFY**
- ./codegen/FIGMA_MAP.md (Figma node ID to Phoenix component mapping - read if working on Figma features) - **READ ONLY - DO NOT MODIFY**

**Important**:

- Only update CONTEXT.md to track your progress and implementation details
- PROJECT_CONTEXT.md is a shared knowledge base - DO NOT modify it during implementation
- Use /refresh-context to archive completed work when CONTEXT.md grows beyond 300 lines

## Git Status

{{GIT_STATUS}}

## Recent Commits

{{COMMIT_LOG}}

## Current Workspace

- Feature: {{FEATURE_NAME}}
- Branch: feature/{{FEATURE_NAME}}
- Working Directory: {{WORKSPACE_PATH}} (you are currently in this directory)
- Phoenix Port: {{PORT}}
- Playwright MCP Port: {{PLAYWRIGHT_MCP_PORT}}

**IMPORTANT**: Work ONLY in the workspace directory ({{WORKSPACE_PATH}}). Do NOT navigate to or modify files in the parent repository directory. The workspace is a git worktree that contains all necessary files for development.

## WORKSPACE ISOLATION REMINDER

**STOP**: Before doing ANYTHING, remember:

- You are in workspace: `{{WORKSPACE_PATH}}`
- This is a FULL project copy at a path like: `/Users/.../project_name/codegen/workspaces/{{FEATURE_NAME}}/`
- ONLY edit files within this workspace
- NEVER copy to parent directories (../../)
- NEVER assume you need to "deploy" changes
- The workspace IS the production environment for your session

## Important: CI Requirements

**CRITICAL**: Run `./codegen/ci.sh` before completing implementation. Fix all issues.

**AUTONOMOUS WORK**: Continue working until feature is 100% complete and perfect.

## Continue Time

**First Action**: Log continuation time in CONTEXT.md:

```bash
date -u +"%a %b %d %H:%M:%S UTC %Y"
```

Review current stage and recent changes, then continue implementation.

**Plan Loading Strategy**:

- **READ ./codegen/plan/overview.md** if you need to refresh feature context
- **Load step files based on CONTEXT.md** - Only read ./codegen/plan/steps/ files for the step you're currently working on
  - Step files use naming convention: step-01-setup.md, step-02-core.md, etc.
- **Check CONTEXT.md FIRST** to understand current stage and which step files are relevant

**Rule Loading**: This is an implementation session - load workflow.md and project-specific rules based on your tech stack (check AGENTS.md for guidance). **IMPORTANT: Check CONTEXT.md FIRST to see if Figma work is pending. Only load ui-implementation.md and FIGMA_MAP.md if CONTEXT.md doesn't show "Figma Status: ✅ COMPLETE".**
