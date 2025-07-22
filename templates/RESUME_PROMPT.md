# Resuming: {{PLAN_TITLE}}

Continue implementing the plan using context from files in your workspace:

- ./codegen/PLAN.md (implementation plan, ~50-100 lines) - READ ONLY
- ./codegen/CONTEXT.md (your working document - check current stage, ~200-300 lines) - **UPDATE THIS FILE**
- ./codegen/PROJECT_CONTEXT.md (project knowledge base, ~150-250 lines) - **READ ONLY - DO NOT MODIFY**

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

## Important: CI Requirements

**CRITICAL**: Run `./codegen/ci.sh` before completing implementation. Fix all issues.

**AUTONOMOUS WORK**: Continue working until feature is 100% complete and perfect.

## Continue Time

**First Action**: Log continuation time in CONTEXT.md:

```bash
date -u +"%a %b %d %H:%M:%S UTC %Y"
```

Review current stage and recent changes, then continue implementation.
