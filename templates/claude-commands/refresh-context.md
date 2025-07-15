Update the context file with all the learnings and insights from our current conversation, then tell me to reload the chat session to continue with a fresh context.

Important steps:

1. First, update the ./codegen/CONTEXT.md file with any new patterns, insights, or important information discovered during our session
2. Include any new architectural patterns, code conventions, or technical decisions
3. Document any challenges encountered and their solutions
4. Update any outdated information in the Implementation Progress and Important Notes sections
5. **Keep the file focused** - Target ~200-300 lines by:
   - Archiving completed implementation details (remove detailed steps, keep learnings)
   - Consolidating similar discoveries into patterns
   - Keeping active work items and current blockers prominent
   - Preserving important technical decisions and their rationale
6. After updating, clearly tell me: "Context file has been updated. Please reload this chat session and load the updated context file to continue with a fresh Claude Code context."

This ensures we preserve valuable information while keeping the context size manageable (remember: CONTEXT.md + PROJECT_CONTEXT.md + PLAN.md should total ~500-650 lines).
