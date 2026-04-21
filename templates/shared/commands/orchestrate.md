---
description: Load project context and rules, then delegate input to the appropriate agent
argument-hint: [file path or requirement]
---

You are the orchestrator. Before any work:

**🚨 STRICT ORDER — do NOT read any files before steps 1 and 2 are complete.**

1. Create the session log at `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md` — this is your FIRST action. If this is a multi-step task resuming a prior session, check `./codegen/logging/` for an existing progress file or step log with the same slug before creating a new one — if found, read it to determine where to resume rather than overwriting.

2. Stamp the session log with a `## Version Stamp` section capturing combobulate, context, codegen, and claude-cli versions. Run this bash snippet and append its output verbatim to the session log (replace `<SESSION_LOG>` with the path from step 1):

   ```bash
   {
     echo ""
     echo "## Version Stamp"
     echo ""
     echo "- combobulate: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
     echo "- context: $(git -C ./codegen/context rev-parse --short HEAD 2>/dev/null || echo unknown)"
     echo "- codegen: $(git -C ./codegen/rules rev-parse --short HEAD 2>/dev/null || echo unknown)"
     echo "- claude: $(claude --version 2>/dev/null || echo unknown)"
     echo "- stamped_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
   } >> <SESSION_LOG>
   ```

3. Load ALL of these rules in order (read each file):
   - `./codegen/rules/shared/subagent-core-rules.md`
   - `./codegen/rules/shared/session-management.md`
   - `./codegen/rules/orchestration/delegation-patterns.md`
   - `./codegen/rules/orchestration/user-communication.md`
   - `./codegen/rules/subagents/git-commit-flow.md`

4. Read `./codegen/PROJECT_CONTEXT.md`.

5. Now delegate and execute: $ARGUMENTS

**🚨 CRITICAL — You ARE the orchestrator. Do NOT spawn yourself as a background agent.**

- ❌ FORBIDDEN: Using `run_in_background=true` on any Agent tool call — background agents lose context and cannot be controlled
- ❌ FORBIDDEN: Launching another orchestrator agent to "do the work" — you ARE the orchestrator, do it directly
- ✅ REQUIRED: All Task()/Agent() delegations must be synchronous (foreground) — block and wait for completion before proceeding
- ✅ REQUIRED: Execute the full phoenix-developer (or static-site-developer) → verification-engineer → code-reviewer → commit cycle yourself, step by step
