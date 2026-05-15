---
description: Comprehensive code review checking coverage, guidelines, and code quality
argument-hint: [optional focus area]
---

Perform comprehensive code review of current changes.

Follow all patterns from `./codegen/rules/roles/reviewer.md` — PROACTIVELY SCAN for ALL violation patterns.

1. **Load code review rules** — `./codegen/rules/roles/reviewer.md`
2. **Check git status and diff** — `git status`, then `git diff` (unstaged) AND `git diff --cached` (staged)
3. **Load workspace plan** — `./codegen/PLAN.md`
4. **Apply all review patterns** from `./codegen/rules/roles/reviewer.md` systematically:
   - Step impl verification (LINE-BY-LINE)
   - Test coverage analysis (MANDATORY for all functional changes)
   - Skipped test detection (ZERO TOLERANCE)
   - Code organization and type deduplication
   - Security and deployment readiness
5. **Check for context overrides** — `./codegen/CONTEXT.md` may have "code review override" with feature-specific instructions
6. **Generate comprehensive report** per format in `./codegen/rules/roles/reviewer.md`:
   - Step Implementation Verification (MANDATORY)
   - Skipped Tests Analysis (MANDATORY BLOCKING)
   - Functional Change Test Analysis (MANDATORY)
   - Type and Spec Duplication Analysis (MANDATORY)
7. **Save review report** — run `date` first, write to `./codegen/code_review.md` with timestamp header

If user provides focus area, emphasize that aspect while still performing comprehensive check.

**Priority order**: CI Status > Security > Code Cleanliness > Coverage > Code Quality > Documentation > Style
