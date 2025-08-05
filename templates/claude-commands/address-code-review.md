---
description: Address code review findings and update context with changes made
argument-hint: [optional focus area]
---

Address code review findings from `./codegen/code_review.md` and implement required fixes:

**CRITICAL**: This command implements the fixes identified in the code review, not just acknowledges them.

1. **Load code review report** - Read `./codegen/code_review.md` to understand all findings and recommendations

2. **Prioritize critical failures** - Address blocking issues first:

   - **❌ Failures**: Critical issues that must be fixed
   - **🚨 FUNCTIONAL CHANGE TEST ANALYSIS**: Missing tests for functional changes
   - **🧹 Cleanup**: Unused code, unnecessary comments, non-production debug code

3. **Implement fixes systematically**:

   - **Missing tests**: Write unit tests for schema changes, context functions, UI components
   - **Attribute ordering**: Fix alphabetical order in Phoenix components and HEEx templates
   - **Verified routes**: Convert string literals to `~p` syntax
   - **Unused code**: Remove unused functions, imports, variables
   - **Comment hygiene**: Remove obvious/redundant comments
   - **Pipeline flow**: Fix awkward parameter names in pipeline functions
   - **Security issues**: Address hardcoded secrets, input validation problems
   - **Coverage gaps**: Add tests to restore coverage levels

4. **Address warnings** - Handle non-blocking issues:

   - **⚠️ Warnings**: Issues that should be addressed
   - **Coverage decreases**: Justify or restore coverage
   - **Code quality improvements**: Style, readability, documentation

5. **Verify deployment readiness** - Complete infrastructure updates:

   - **🚀 Deployment readiness**: Missing GitHub Actions, Docker, environment variables

6. **Validate fixes**:

   - Run `./codegen/ci.sh` to ensure all fixes work
   - Verify tests pass with new test coverage
   - Check that Credo warnings are resolved
   - Confirm coverage metrics are acceptable

7. **Update context**: Document what was addressed and any remaining items for the context update process

If user provides a focus area in the argument, prioritize that aspect while still addressing critical failures.

**Goal**: Transform all code review findings into actual implemented fixes, not just acknowledgments.
