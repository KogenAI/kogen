# Resuming: {{PLAN_TITLE}}

Continue implementing the plan using context from files in your workspace:

- ./codegen/PLAN.md (implementation plan)
- ./codegen/CONTEXT.md (your working document - check current stage)
- ./codegen/PROJECT_CONTEXT.md (project knowledge base)

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
