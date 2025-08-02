---
description: Update context file with session learnings and prepare for session reload
---

Update the ./codegen/CONTEXT.md file with all learnings and insights from the current conversation, then instruct to reload the chat session.

Steps:

1. Update ./codegen/CONTEXT.md with new patterns, insights, and important information from this session
2. Include new architectural patterns, code conventions, or technical decisions
3. Document challenges encountered and their solutions
4. Update outdated information in Implementation Progress and Important Notes sections
5. **Keep focused** - Target ~200-300 lines by:
   - Archiving completed implementation details (remove detailed steps, keep learnings)
   - Consolidating similar discoveries into patterns
   - Keeping active work items and current blockers prominent
   - Preserving important technical decisions and their rationale
6. After updating, tell user: "Context file has been updated. Please reload this chat session and load the updated context file to continue with a fresh Claude Code context."

Ensure CONTEXT.md + PROJECT_CONTEXT.md + PLAN.md total ~500-650 lines for manageable context size.
