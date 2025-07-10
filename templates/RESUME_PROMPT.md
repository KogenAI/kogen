# Resuming: {{PLAN_TITLE}}

Continue implementing the plan using context from files in your workspace:

- ./codegen/PLAN.md (implementation plan, ~50-100 lines) - READ ONLY
- ./codegen/CONTEXT.md (your working document - check current stage, ~200-300 lines) - **UPDATE THIS FILE**
- ./codegen/PROJECT_CONTEXT.md (project knowledge base, ~300-400 lines) - **READ ONLY - DO NOT MODIFY**

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

## Important: CI Requirements

**CRITICAL**: Before completing any implementation, you MUST ensure CI checks pass.

- Run `./codegen/ci.sh` after making changes to verify code quality
- Fix any formatting, linting, or other issues reported
- Do not consider implementation complete until CI checks pass
- This ensures consistent code quality across the project

Review the current stage in CONTEXT.md and recent changes, then continue implementation.
