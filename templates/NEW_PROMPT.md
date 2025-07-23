# Starting: {{PLAN_TITLE}}

Implement the plan using context from files in your workspace:

- ./codegen/PLAN.md (implementation plan) - READ ONLY
- ./codegen/CONTEXT.md (your working document - track progress here) - **UPDATE THIS FILE**
- ./codegen/PROJECT_CONTEXT.md (project knowledge base) - **READ ONLY - DO NOT MODIFY**

Follow the staged development workflow and update CONTEXT.md as you progress through stages.
**IMPORTANT**: Only modify CONTEXT.md during implementation. PROJECT_CONTEXT.md is a shared resource.

## Current Workspace

- Feature: {{FEATURE_NAME}}
- Branch: feature/{{FEATURE_NAME}}
- Working Directory: {{WORKSPACE_PATH}} (you are currently in this directory)
- Phoenix Port: {{PORT}}
- Playwright MCP Port: {{PLAYWRIGHT_MCP_PORT}}

**IMPORTANT**: Work ONLY in the workspace directory ({{WORKSPACE_PATH}}). Do NOT navigate to or modify files in the parent repository directory. The workspace is a git worktree that contains all necessary files for development.

## Available Context Files

- `./codegen/PLAN.md` - The implementation plan (~50-100 lines) - **READ ONLY**
- `./codegen/CONTEXT.md` - Track your progress and stages here (~200-300 lines) - **UPDATE THIS FILE**
- `./codegen/PROJECT_CONTEXT.md` - Project architecture and patterns (~150-250 lines) - **READ ONLY - DO NOT MODIFY**
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

Review the plan and current context, then begin implementation.

**Rule Loading**: This is an implementation session - load workflow.md and project-specific rules based on your tech stack (as guided by {{AGENT_CONTEXT_FILE}}).
