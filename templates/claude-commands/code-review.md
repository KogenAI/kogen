---
description: Comprehensive code review checking coverage, guidelines, and code quality
argument-hint: [optional focus area]
---

Perform a comprehensive code review of the current changes and codebase.

**CRITICAL**: Do NOT wait for user guidance. PROACTIVELY SCAN for ALL violation patterns. You must catch issues automatically, not after the user points them out.

1. **Check git status and diff** - Use `git status` to see all changes, then `git diff` (unstaged) AND `git diff --cached` (staged) to examine ALL modifications in the current branch
2. **Load workspace plan** - Read `./codegen/PLAN.md` to understand the goal for this workspace
3. **🚨 CRITICAL - Verify step implementation completeness** - MANDATORY step plan verification:
   - Read `./codegen/CONTEXT.md` to identify current step being implemented
   - Read the corresponding step plan file (e.g., `./codegen/plan/steps/step-01-infrastructure.md`)
   - **LINE-BY-LINE verification**: Check EVERY requirement in step plan is implemented
   - **Missing implementations are BLOCKING failures** - no exceptions
   - Verify all file changes, configuration updates, and dependency additions match the plan exactly
4. **Check for context overrides** - Look for `./codegen/CONTEXT.md` which may explicitly mention "code review override" with feature-specific instructions that override standard rules
5. **Line-by-line diff analysis** - Review each changed line in git diff to verify it contributes to achieving the PLAN.md goal
   - **Proactively scan for ALL patterns** - Don't wait for user guidance, actively search for every violation type
   - **🚨 MANDATORY TEST REQUIREMENT CHECK**: For EVERY functional change (schema validations, context functions, UI components, business logic, API endpoints), immediately verify corresponding tests exist or are updated. This is BLOCKING - no exceptions.
6. **Load project rules** - Read all relevant rules from the rules directory (check current directory structure, don't assume parent paths)
7. **Review code quality** - SYSTEMATICALLY CHECK:
   - Check adherence to rules in RULES.md
   - Verify Elixir code follows elixir-code-generation.md guidelines
   - Ensure Phoenix patterns follow phoenix.md rules
   - **Verified routes**: SCAN for string literal routes like `visit("/path")` - ALL must use `~p` syntax
   - Validate test coverage and testing patterns
   - **🚨 BLOCKING FAILURE - ANY functional changes without tests**: AGGRESSIVELY scan for ALL code changes that modify behavior and verify corresponding test coverage exists:
     - **Schema validations**: validate_length, validate_format, validate_required, unique_constraint, field changes
     - **Context functions**: New functions, modified business logic, query changes, data transformations
     - **LiveView/Controllers**: New actions, modified event handlers, route changes, parameter handling
     - **Components**: New components, modified rendering logic, attribute changes, conditional logic
     - **UI behavior**: Form validation, JavaScript interactions, responsive behavior, accessibility features
     - **API endpoints**: New endpoints, modified responses, authentication changes, parameter validation
     - **Business logic**: Calculations, state transitions, workflow changes, permission checks
     - **Database changes**: Migrations, queries, indexes, constraints
     - **Configuration**: Environment-dependent behavior, feature flags, external service integration
     - **SEARCH STRATEGY**: For each change, immediately grep test files for related test coverage
     - **Zero tolerance**: EVERY functional change must have corresponding test updates - no exceptions
8. **Coverage analysis**:
   - Check for coveralls.json or coverage reports
   - Compare current coverage to previous baseline
   - **WARN on coverage decreases**: Flag any coverage drops with clear before/after percentages (rare exceptions allowed but must be justified)
   - Identify untested code paths
9. **CI/Quality checks**:
   - Run `make ci` if available to check build status
   - Verify no Credo warnings (zero-tolerance per elixir-ci.md)
   - Check for compilation warnings
   - Validate test suite passes
10. **Code cleanliness and maintenance** - ACTIVELY SEARCH for these patterns:
    - **Unused code detection**: Find functions, modules, variables, imports not referenced anywhere
    - **🚨 CRITICAL - Useless functions**: AGGRESSIVELY scan for functions that do nothing useful and MUST be removed:
      - `setup do :ok end` (does nothing - remove entirely)
      - Empty function bodies that just return defaults
      - Functions that only return static values without logic
      - Test setup functions that provide no actual setup
      - Placeholder functions with no implementation
    - **Non-production code removal**: Remove debug prints, console.log, commented-out code blocks, test scaffolding
    - **Backwards compatibility cleanup**: Flag any compatibility shims, deprecated patterns, or transition code
    - **CRITICAL - Comment hygiene**: Aggressively remove unnecessary comments - good variable/function names should be self-documenting
    - **Test comments exception**: Only allow truly descriptive comments in tests that add meaningful context
    - **Comment accuracy**: VERIFY all comments are factually correct and make sense in context - remove misleading explanations
    - **Attribute ordering**: SCAN ALL Phoenix component attr definitions and HEEx component calls for alphabetical order violations
    - **Elixir code organization**: VERIFY proper ordering and grouping in all modules:
      - Group and sort alphabetically: `use`, `import`, `require`, `alias` statements
      - Within each group, maintain alphabetical order
      - Proper spacing between groups and sections
      - `@endpoint` and other module attributes in correct position
11. **Security and best practices**:
    - Check for hardcoded secrets or credentials
    - Verify proper error handling
    - Review database migration safety
    - Validate input sanitization
12. **Deployment and infrastructure consistency**:
    - **GitHub Actions**: Check if feature requires CI/CD pipeline updates (.github/workflows/)
    - **Deployment configs**: Verify Fly.io, Kamal, or other deployment tool configurations are updated if needed
    - **Dockerfile changes**: Ensure Docker configuration reflects any new dependencies or build requirements
    - **Environment variables**: Check if new config vars need to be added to deployment environments
    - **Database migrations**: Verify deployment includes necessary migration steps
13. **Documentation and readability** - EXAMINE ALL CODE:
    - Ensure functions have proper @spec annotations
    - Verify module documentation
    - Check that code is self-documenting through clear naming
    - **Pipeline flow**: SCAN pipeline functions for awkward parameter names that break natural reading flow
14. **Generate review report**:
    - **🎯 Goal alignment**: Whether each change contributes to the PLAN.md objective
    - **📋 Step Implementation Verification**: MANDATORY section - Line-by-line verification of step plan completion:
      - List EVERY requirement from the step plan file
      - For each requirement, explicitly state: "✅ IMPLEMENTED" or "❌ MISSING"
      - Mark ANY missing implementations as BLOCKING failures
      - Include file paths and line numbers for implemented requirements
    - **🚀 Deployment readiness**: Missing infrastructure/deployment updates needed for production
    - **✅ Passes**: List what meets standards
    - **⚠️ Warnings**: Issues that should be addressed
    - **❌ Failures**: Critical issues that must be fixed
    - **🚨 FUNCTIONAL CHANGE TEST ANALYSIS**: MANDATORY section - List every functional change and whether tests exist:
      - **Schema changes**: validate\_\*, constraints, field modifications
      - **Context changes**: New/modified functions, business logic updates
      - **UI changes**: Components, LiveViews, templates, JavaScript behavior
      - **API changes**: Endpoints, controllers, parameter handling
      - **Business logic**: Calculations, workflows, state management
      - For each category found, explicitly state: "Found [change type] - tests: ✅ EXIST / ❌ MISSING"
      - Mark ANY missing tests as BLOCKING failures
      - Include specific examples of what should be tested for each change
    - **🧹 Cleanup**: Unused code, EXCESSIVE unnecessary comments, non-production debug code to remove
    - **📊 Coverage**: Current vs baseline coverage metrics
    - **🔧 Recommendations**: Specific improvement suggestions

15. **Save review report**:
    - First run `date` command to get current timestamp
    - Write the complete review analysis to `./codegen/code_review.md` with that fresh timestamp header for future reference and use by other agents

If user provides a focus area in the argument, emphasize that aspect of the review while still performing the comprehensive check.

Priority order: CI Status > Security > Code Cleanliness > Coverage > Code Quality > Documentation > Style
