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
