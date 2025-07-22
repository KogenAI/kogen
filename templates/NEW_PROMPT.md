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

**CRITICAL**: Before completing any implementation, you MUST ensure CI checks pass.

- Run `./codegen/ci.sh` after making changes to verify code quality
- Fix any formatting, linting, or other issues reported
- Do not consider implementation complete until CI checks pass
- This ensures consistent code quality across the project

**CRITICAL AUTONOMOUS WORK**: You MUST work for 2-6 hours continuously until the feature is COMPLETELY finished and working perfectly in the browser. Never stop after compilation fixes, template changes, or backend completion - these are milestones, not endpoints.

**PROHIBITED STOPPING POINTS**:

- ❌ After fixing compilation or template errors
- ❌ After backend implementation complete
- ❌ After CI passes (still need browser validation)
- ❌ After "should work now" moments
- ❌ After adding missing components or attributes

**MANDATORY COMPLETION CRITERIA**:

- ✅ Feature works perfectly in actual browser
- ✅ Mobile, tablet, desktop all tested and functional
- ✅ All user workflows validated end-to-end
- ✅ CI passes AND browser validation complete
- ✅ User can immediately use feature without additional work

**TEMPLATE FIX PROTOCOL**: After any compilation fix, IMMEDIATELY test in browser and continue working until 100% complete.

Start by reviewing the plan and current context, then begin implementation and work until completely finished.
