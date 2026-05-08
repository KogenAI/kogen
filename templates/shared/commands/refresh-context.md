---
description: Update context file with session learnings and prepare for session reload
---

Update `./codegen/CONTEXT.md` with all learnings from current conversation, then instruct to reload chat session.

Steps:

1. **PRESERVE CRITICAL VERIFICATION INFO** — never lose:
   - Current step completion status (✅ COMPLETE / ⏳ IN PROGRESS)
   - Verification evidence section with CI results and test outcomes
   - Step context file references (step-XX-name.md)
   - Last verification timestamp

2. **DISCOVER RELEVANT RULES & RECIPES** for next session:
   - Check `./codegen/rules/subagents/INDEX.md` for applicable rules based on next step reqs
   - Check `./codegen/recipes/INDEX.md` for solutions to problems encountered

3. Update `./codegen/CONTEXT.md` with new patterns, insights, and important info from this session
4. Include new architectural patterns, code conventions, technical decisions
5. Document challenges and solutions
6. Update Implementation Progress with completed steps and verification status
7. **Add Rule/Recipe References** section if needed:

   ```
   ## Relevant Rules/Recipes for Next Session
   - Rules: phoenix.md (LiveView patterns), testing.md (async setup)
   - Recipes: phoenix-async-feature-test-liveview.md (if DBConnection errors)
   ```

8. **Keep focused** — target ~50-100 lines:
   - PRESERVE step completion status and verification evidence
   - MOVE detailed impl to step context files
   - Keep only current focus, next steps, and session tracking in main file
   - Consolidate patterns into brief learnings

9. **Ensure verification continuity:**
   - Current Stage shows accurate step status
   - Verification Evidence preserved
   - Next step clearly identified
   - Incomplete verification clearly marked
   - Rules/recipes needed for next step noted

10. After updating, tell user: "Context file updated with relevant rule/recipe references. Reload chat session and load updated context file to continue with fresh context."

Target ~50-100 lines. Detailed impl goes in step context files.
