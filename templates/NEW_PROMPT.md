# Starting: {{PLAN_TITLE}}

Implement the plan using context from files in your workspace:

- ./codegen/plan/overview.md (feature overview & step sequence) - READ ONLY
- ./codegen/plan/steps/ (detailed step implementations - load as needed) - READ ONLY
  - Step files use naming convention: step-01-setup.md, step-02-core.md, etc.
- ./codegen/CONTEXT.md (your working document - track progress here) - **UPDATE THIS FILE**
- ./codegen/PROJECT_CONTEXT.md (project knowledge base) - **READ ONLY - DO NOT MODIFY**
- ./codegen/FIGMA_MAP.md (Figma node ID to Phoenix component mapping - read if working on Figma features) - **READ ONLY - DO NOT MODIFY**

Follow the staged development workflow and update CONTEXT.md as you progress through stages.
**IMPORTANT**: Only modify CONTEXT.md during implementation. PROJECT_CONTEXT.md is a shared resource.

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
- `./codegen/FIGMA_MAP.md` - Figma node ID to Phoenix component mapping (read if working on Figma features) - **READ ONLY - DO NOT MODIFY**
- `./{{AGENT_CONTEXT_FILE}}` - Repository-specific guidance - **READ ONLY**

**Note**:

- These files are optimized to fit efficiently in Claude's context window
- Keep CONTEXT.md focused by using /refresh-context to archive completed work when it grows beyond 300 lines
- PROJECT_CONTEXT.md contains shared project knowledge - it should only be updated via `ocg update-context` after feature completion

## Important: CI Requirements

**CRITICAL**: Run `./codegen/ci.sh` before completing implementation. Fix all issues.

**AUTONOMOUS WORK**: Work continuously until feature is 100% complete and perfect.

## Start Time

**First Action**: Log start time in CONTEXT.md:

```bash
date -u +"%a %b %d %H:%M:%S UTC %Y"
```

Review the plan overview and current context, then begin implementation.

**Plan Loading Strategy**:

- **READ ./codegen/plan/overview.md IMMEDIATELY** - Contains feature goals, architecture, and step sequence
- **Load step files selectively** - Only read ./codegen/plan/steps/ files when working on that specific step
- **Check CONTEXT.md** to understand which step you should be working on

**Rule Loading**: This is an implementation session - load workflow.md and project-specific rules based on your tech stack (as guided by {{AGENT_CONTEXT_FILE}}). The agent context file will guide you on whether to load figma.md and FIGMA_MAP.md based on the feature type.
