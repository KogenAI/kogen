# /validate-plan Command

Validate current plan context for logical consistency, feasibility, and quality.

## Usage

```
/validate-plan
```

## What It Does

Second-pair-of-eyes review identifying:

### Logic & Consistency

- Contradictory reqs — steps conflicting with each other
- Missing dependencies — steps depending on unplanned work
- Circular dependencies — impossible ordering
- Incomplete sequences — missing critical steps
- Scope creep — reqs expanding beyond stated goals

### Technical Feasibility

- Architectural anti-patterns — design tokens in Elixir modules, business logic in templates
- Framework violations — patterns conflicting with framework standards
- Technology mismatches — wrong tools
- Performance concerns — approaches causing bottlenecks
- Security gaps — missing auth, validation, or authorization
- Scalability issues — solutions that won't handle growth

### Impl Reality

- Overly complex solutions — elaborate fixes for simple problems
- Underestimated complexity — simple-sounding tasks that are complex
- Missing edge cases — error handling, empty states, validation failures
- Integration assumptions — assuming external systems work perfectly
- Resource reqs — steps needing unavailable tools or access
- Invalid commands/references — non-existent commands, incorrect syntax, outdated patterns
- Redundant impls — building new components when existing solutions work

### Goal Alignment

- Feature drift — steps not serving stated objective
- Gold plating — unnecessary features
- UX gaps — technical focus without user impact
- Business logic misalignment — technical solutions not matching business rules

### Workflow & Process

- Unrealistic timelines
- Testing gaps — missing verification steps
- Documentation blind spots — changes without doc updates
- Migration concerns — DB or code changes without migration strategy
- Temporary file cleanup — missing cleanup for temp files, routes, test components

## Output Format

```
## Plan Validation Report

### CRITICAL ISSUES (Must Fix)
- **Logic Error**: Step 2 requires user auth but Step 1 removes auth system
- **Architecture**: Design tokens belong in Tailwind config, not Elixir modules

### CONCERNS (Should Address)
- **Complexity**: Email notification system overly complex for simple signup flow
- **Missing**: No error handling for external API failures

### SUGGESTIONS (Consider)
- **Simplification**: Could use existing Phoenix components instead of custom ones
- **Enhancement**: Consider loading states for better UX

### Summary
- 2 critical issues blocking impl
- 3 concerns that could cause problems
- 4 suggestions for improvement

### Overall Assessment
Plan shows good technical understanding but has logical inconsistencies in Steps 1-2.
```

## Validation Approach

- Verify before criticizing — check file existence, deps, assumptions before flagging
- Evidence-based — only report problems with concrete proof, not hypothetical concerns
- Question assumptions — challenge "obvious" solutions with actual investigation
- Spot real contradictions — find conflicting reqs that actually conflict
- Reality check complexity — flag unrealistic expectations with specific reasoning
- Fill logical gaps — identify genuinely missing pieces
- Suggest alternatives — propose simpler approaches only when current approach is problematic
- Validate commands and references — verify commands, files, patterns actually exist
- Track temp artifacts — ensure temp files/routes/components have explicit cleanup steps
- Check for existing solutions — investigate whether functionality already exists

NEVER report placeholder node IDs, commands, or files as issues without actual verification. Use tools to confirm problems exist.
