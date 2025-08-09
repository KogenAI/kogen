---
description: Update context file with session learnings and prepare for session reload
---

Update the ./codegen/CONTEXT.md file with all learnings and insights from the current conversation, then instruct to reload the chat session.

Steps:

1. **PRESERVE CRITICAL VERIFICATION INFORMATION** - Never lose:

   - Current step completion status (✅ COMPLETE / ⏳ IN PROGRESS)
   - Verification evidence section with CI results and test outcomes
   - Step context file references (step-XX-name.md)
   - Last verification timestamp

2. **DISCOVER RELEVANT RULES & RECIPES** for next session:

   - Check `./codegen/rules/subagents/INDEX.md` for applicable rules based on:
     - Next step requirements (grep keywords from step plan)
     - Known issues or patterns encountered
     - Agent type that will handle next step
   - Check `./codegen/recipes/INDEX.md` for solutions to:
     - Problems encountered this session
     - Patterns needed for next step
     - Common issues from error messages

3. Update ./codegen/CONTEXT.md with new patterns, insights, and important information from this session
4. Include new architectural patterns, code conventions, or technical decisions
5. Document challenges encountered and their solutions
6. Update Implementation Progress section with completed steps and verification status
7. **Add Rule/Recipe References** section if needed:

   ```
   ## Relevant Rules/Recipes for Next Session
   - Rules: phoenix.md (LiveView patterns), testing.md (async setup)
   - Recipes: phoenix-async-feature-testing-with-liveview.md (if DBConnection errors)
   ```

8. **Keep focused** - Target ~50-100 lines by:

   - **PRESERVE step completion status and verification evidence**
   - **MOVE detailed implementation to step context files** (not main CONTEXT.md)
   - Keep only current focus, next steps, and session tracking in main file
   - Archive completed step details to their respective step-XX-name.md files
   - Consolidate patterns into brief learnings
   - Maintain clear "what's verified vs what needs work" status

9. **Ensure verification continuity**:

   - Current Stage section shows accurate step status
   - Verification Evidence section preserved
   - Next step clearly identified
   - Any incomplete verification clearly marked
   - Rules/recipes needed for next step noted

10. After updating, tell user: "Context file has been updated with relevant rule/recipe references. Please reload this chat session and load the updated context file to continue with a fresh Claude Code context."

Ensure CONTEXT.md stays ~50-100 lines. Detailed implementation goes in step context files. Total context load should be manageable.
