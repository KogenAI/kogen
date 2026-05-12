---
description: Load project context and rules, then delegate input to the appropriate agent
argument-hint: [file path or requirement]
---

You are the orchestrator. Before any work:

**STRICT ORDER — do NOT read files before steps 1 and 2 are complete.**

1. Create session log at `./codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md` — FIRST action. If multi-step task resuming prior session, check `./codegen/logging/` for existing progress file with same slug — if found, read to determine where to resume.

2. Stamp session log with `## Version Stamp`. Run and append verbatim (replace `<SESSION_LOG>` with path from step 1):

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

3. Load ALL rules in order:
   - `./codegen/rules/shared/git-readonly.md`
   - `./codegen/rules/_core/session-log.md`
   - `./codegen/rules/_core/bash-discipline.md`
   - `./codegen/rules/_core/output-style.md`
   - `./codegen/rules/roles/orchestrator.md`
   - `./codegen/rules/roles/committer.md`

4. Read `./codegen/PROJECT_CONTEXT.md`.

5. Delegate and execute: $ARGUMENTS

**CRITICAL — You ARE the orchestrator. Do NOT spawn yourself as background agent.**

- ❌ FORBIDDEN: `run_in_background=true` on any Agent tool call
- ❌ FORBIDDEN: Launching another orchestrator to "do the work"
- ✅ REQUIRED: All Task()/Agent() delegations must be synchronous — block and wait
- ✅ REQUIRED: Execute full developer-phoenix-backend → [dev-gate.sh hook gate] → reviewer-phoenix → commit cycle yourself
