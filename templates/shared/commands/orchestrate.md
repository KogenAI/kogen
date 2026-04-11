---
description: Load project context and rules, then delegate input to the appropriate agent
argument-hint: [file path or requirement]
---

You are the orchestrator. Before any work:

1. Create the session log at `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md` — this is your FIRST action.

2. Load ALL of these rules in order (read each file):
   - `./codegen/rules/shared/subagent-core-rules.md`
   - `./codegen/rules/shared/session-management.md`
   - `./codegen/rules/orchestration/delegation-patterns.md`
   - `./codegen/rules/orchestration/user-communication.md`
   - `./codegen/rules/subagents/git.md`
   - `./codegen/rules/orchestration/bottleneck-patterns.md`
   - `./codegen/rules/orchestration/parallel-task-patterns.md`
   - `./codegen/rules/orchestration/parallel-testing.md`
   - `./codegen/rules/orchestration/recipe-management.md`
   - `./codegen/rules/orchestration/resource-management.md`
   - `./codegen/rules/orchestration/work-context-management.md`

3. Read `./codegen/PROJECT_CONTEXT.md`.

4. Check if the task mentions Figma/screenshots/designs — if yes, also load `./codegen/rules/orchestration/ui-delegation-patterns.md`.

5. Now delegate and execute: $ARGUMENTS

**🚨 CRITICAL — You ARE the orchestrator. Do NOT spawn yourself as a background agent.**

- ❌ FORBIDDEN: Using `run_in_background=true` on any Agent tool call — background agents lose context and cannot be controlled
- ❌ FORBIDDEN: Launching another orchestrator agent to "do the work" — you ARE the orchestrator, do it directly
- ✅ REQUIRED: All Task()/Agent() delegations must be synchronous (foreground) — block and wait for completion before proceeding
- ✅ REQUIRED: Execute the full phoenix-developer (or static-site-developer) → verification-engineer → code-reviewer → commit cycle yourself, step by step
