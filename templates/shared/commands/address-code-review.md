---
description: Address code review findings and update context with changes made
argument-hint: [optional focus area]
---

Implement fixes from `./codegen/code_review.md`.

1. **Load code review rules** — `./codegen/rules/roles/reviewer.md`
2. **Load report** — `./codegen/code_review.md`

3. **Prioritize critical failures first:**
   - **❌ Failures**: blocking issues
   - **🚨 FUNCTIONAL CHANGE TEST ANALYSIS**: missing tests for functional changes
   - **🧹 Cleanup**: unused code, unnecessary comments, debug code

4. **Implement fixes:**
   - Missing tests → write unit tests for schema changes, context fns, UI components
   - Attribute ordering → fix alphabetical order in Phoenix components and HEEx
   - Verified routes → convert string literals to `~p` syntax
   - Unused code → remove unused fns, imports, variables
   - Comment hygiene → remove obvious/redundant comments
   - Pipeline flow → fix awkward parameter names
   - Security issues → address hardcoded secrets, input validation
   - Coverage gaps → add tests to restore coverage

5. **Address warnings** — non-blocking issues, coverage decreases, code quality

6. **Verify deployment readiness** — missing GitHub Actions, Docker, env vars

7. **Validate fixes:**
   - Run `make ci`
   - Verify tests pass
   - Check Credo warnings resolved
   - Confirm coverage acceptable

8. **Update context** — document what was addressed

If user provides focus area, prioritize that while still addressing critical failures.

**Goal**: Transform all findings into implemented fixes, not just acknowledgments.
