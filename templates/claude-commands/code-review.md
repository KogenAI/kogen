---
description: Comprehensive code review checking coverage, guidelines, and code quality
argument-hint: [optional focus area]
---

Perform a comprehensive code review of the current changes and codebase.

**CRITICAL**: Follow all patterns and requirements from `./codegen/rules/subagents/code-review.md` - Do NOT wait for user guidance. PROACTIVELY SCAN for ALL violation patterns.

1. **Load code review rules** - Read `./codegen/rules/subagents/code-review.md` for comprehensive review patterns
2. **Check git status and diff** - Use `git status` to see all changes, then `git diff` (unstaged) AND `git diff --cached` (staged) to examine ALL modifications
3. **Load workspace plan** - Read `./codegen/PLAN.md` to understand the goal for this workspace
4. **Apply all code review patterns** - Follow `./codegen/rules/subagents/code-review.md` systematically:
   - Step implementation verification (LINE-BY-LINE)
   - Test coverage analysis (MANDATORY for all functional changes)
   - Skipped test detection (ZERO TOLERANCE)
   - Code organization and type deduplication
   - Security and deployment readiness
   - All other patterns specified in the rules
5. **Check for context overrides** - Look for `./codegen/CONTEXT.md` which may explicitly mention "code review override" with feature-specific instructions
6. **Generate comprehensive report** - Following the format specified in `./codegen/rules/subagents/code-review.md`:
   - Step Implementation Verification (MANDATORY)
   - Skipped Tests Analysis (MANDATORY BLOCKING)
   - Functional Change Test Analysis (MANDATORY)
   - Type and Spec Duplication Analysis (MANDATORY)
   - All other sections as specified in rules
7. **Save review report**:
   - First run `date` command to get current timestamp
   - Write the complete review analysis to `./codegen/code_review.md` with that fresh timestamp header for future reference and use by other agents

If user provides a focus area in the argument, emphasize that aspect of the review while still performing the comprehensive check.

**Priority order**: CI Status > Security > Code Cleanliness > Coverage > Code Quality > Documentation > Style
