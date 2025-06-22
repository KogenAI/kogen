# Starting: {{PLAN_TITLE}}

Implement the plan in codegen/PLAN.md using context from:

- codegen/CONTEXT.md (your working document - track progress here)
- codegen/PROJECT_CONTEXT.md (project knowledge base)

Follow the staged development workflow and update CONTEXT.md as you progress through stages.

## Current Workspace

- Feature: {{FEATURE_NAME}}
- Branch: feature/{{FEATURE_NAME}}
- Working Directory: {{WORKSPACE_PATH}}
- Phoenix Port: {{PORT}}
- Playwright MCP Port: {{PLAYWRIGHT_MCP_PORT}}

## Available Context Files

- `/codegen/PLAN.md` - The implementation plan
- `/codegen/CONTEXT.md` - Track your progress and stages here
- `/codegen/PROJECT_CONTEXT.md` - Project architecture and patterns
- `/CLAUDE.md` - Repository-specific guidance

## Important: CI Requirements

**CRITICAL**: Before completing any implementation, you MUST ensure CI checks pass.

- Run `./codegen/ci.sh` after making changes to verify code quality
- Fix any formatting, linting, or other issues reported
- Do not consider implementation complete until CI checks pass
- This ensures consistent code quality across the project

Start by reviewing the plan and current context, then begin implementation.
