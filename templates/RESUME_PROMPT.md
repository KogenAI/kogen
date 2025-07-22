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

**CRITICAL**: Before completing any implementation, you MUST ensure CI checks pass.

- Run `./codegen/ci.sh` after making changes to verify code quality
- Fix any formatting, linting, or other issues reported
- Do not consider implementation complete until CI checks pass
- This ensures consistent code quality across the project

**CRITICAL AUTONOMOUS WORK**: You MUST continue working for 2-6 hours until the feature is COMPLETELY finished and working perfectly in the browser. Do not stop after template fixes, compilation fixes, or context refreshes - these are implementation milestones, not completion points.

**PROHIBITED STOPPING POINTS**:

- ❌ After fixing compilation errors (this is when real testing begins)
- ❌ After template changes or adding missing components
- ❌ After running `/refresh-context` (continue with clean context)
- ❌ When encountering "should work now" scenarios (verify it actually works)
- ❌ After backend implementation complete (frontend testing required)
- ❌ After CI passing (still need browser validation)
- ❌ After adding missing attributes or fixing syntax errors

**MANDATORY COMPLETION PROTOCOL**:

1. **IMMEDIATELY** test any fixes in browser using Playwright MCP
2. **VERIFY** all functionality works end-to-end in actual browser
3. **CONTINUE** fixing any discovered issues without stopping
4. **TEST** mobile, tablet, desktop responsiveness completely
5. **WORK** until user can use feature immediately without additional work
6. **ONLY STOP** when everything is perfect AND browser validated AND CI passes

**TEMPLATE FIX ENFORCEMENT**: After fixing any template compilation issue, you MUST immediately test in browser and continue working. Template fixes are the START of testing, never the end of work.

Review the current stage in CONTEXT.md and recent changes, then continue implementation until 100% complete.
