# /validate-plan Command

Provides comprehensive validation of the current plan context for logical consistency, feasibility, and quality.

## Usage

```
/validate-plan
```

## What It Does

Acts as a second pair of eyes reviewing the loaded plan context to identify:

### Validation Categories

#### 🧠 Logic & Consistency

- **Contradictory requirements** - Steps that conflict with each other
- **Missing dependencies** - Steps that depend on unplanned work
- **Circular dependencies** - Steps that create impossible ordering
- **Incomplete sequences** - Missing critical steps in workflows
- **Scope creep** - Requirements that expand beyond stated goals

#### 🏗️ Technical Feasibility

- **Architectural anti-patterns** - Design tokens in Elixir modules, business logic in templates
- **Framework violations** - Inventing new patterns that conflict with framework standards and best practices
- **Technology mismatches** - Using wrong tools for the job
- **Performance concerns** - Approaches that will cause bottlenecks
- **Security gaps** - Missing authentication, validation, or authorization
- **Scalability issues** - Solutions that won't handle growth

#### 📋 Implementation Reality

- **Overly complex solutions** - Simple problems with elaborate fixes
- **Underestimated complexity** - Simple-sounding tasks that are actually complex
- **Missing edge cases** - Error handling, empty states, validation failures
- **Integration assumptions** - Assuming external systems will work perfectly
- **Resource requirements** - Steps that need unavailable tools or access
- **Invalid commands/references** - Non-existent commands, incorrect syntax, or outdated patterns
- **Redundant implementations** - Building new components when existing solutions already handle the requirements

#### 🎯 Goal Alignment

- **Feature drift** - Steps that don't serve the stated objective
- **Gold plating** - Unnecessary bells and whistles
- **User experience gaps** - Technical focus without considering user impact
- **Business logic misalignment** - Technical solutions that don't match business rules

#### 🔄 Workflow & Process

- **Unrealistic timelines** - Steps that claim unrealistic completion times
- **Testing gaps** - Missing verification or quality assurance steps
- **Documentation blind spots** - Changes without proper documentation updates
- **Migration concerns** - Database or code changes without migration strategy
- **Temporary file cleanup** - Missing cleanup steps for temporary files, routes, or test components

## Output Format

Provides a structured assessment:

```
## Plan Validation Report

### 🔴 CRITICAL ISSUES (Must Fix)
- **Logic Error**: Step 2 requires user authentication but Step 1 removes the auth system
- **Architecture**: Design tokens belong in Tailwind config, not Elixir modules

### 🟡 CONCERNS (Should Address)
- **Complexity**: Email notification system seems overly complex for a simple signup flow
- **Missing**: No error handling specified for external API failures

### 🔵 SUGGESTIONS (Consider)
- **Simplification**: Could use existing Phoenix components instead of building custom ones
- **Enhancement**: Consider adding loading states for better UX

### 📊 Summary
- 2 critical issue(s) that block implementation
- 3 concern(s) that could cause problems
- 4 suggestion(s) for improvement

### 🎯 Overall Assessment
Plan shows good technical understanding but has logical inconsistencies in Steps 1-2 that need resolution before proceeding.
```

## Validation Approach

- **Verify before criticizing** - Check file existence, dependencies, and assumptions before flagging issues
- **Evidence-based analysis** - Only report problems with concrete proof, not hypothetical concerns
- **Question assumptions** - Challenge "obvious" solutions with actual investigation
- **Spot real contradictions** - Find conflicting requirements that actually conflict
- **Reality check complexity** - Flag unrealistic expectations with specific reasoning
- **Fill logical gaps** - Identify missing pieces that are genuinely missing
- **Suggest alternatives** - Propose simpler approaches only when current approach is problematic
- **Validate commands and references** - Verify that mentioned commands, files, and patterns actually exist in the project
- **Track temporary artifacts** - Ensure temporary files, routes, components, or test pages have explicit cleanup steps
- **Check for existing solutions** - Investigate whether functionality already exists before planning new implementations

**CRITICAL**: Always verify claims before reporting them as issues. Investigate and confirm problems actually exist before flagging them. This includes checking whether referenced commands are valid and files/patterns mentioned actually exist in the codebase.

**WARNING**: Do NOT assume something is wrong based on appearance alone. Use tools to actually verify:

- Figma node IDs that "look like placeholders" may be real - check the actual Figma file
- Commands that "seem incorrect" may be valid - verify they exist in the project
- Files that "appear missing" may exist - check the actual file system
- Only report issues with concrete evidence from actual investigation

## Benefits

- **Prevent implementation disasters** - Catch flawed logic before coding starts
- **Improve plan quality** - Get objective feedback on approach
- **Save development time** - Fix issues in planning rather than during implementation
- **Reduce scope creep** - Keep focus on actual requirements
- **Learning opportunity** - Understand common planning pitfalls

Use during planning sessions to validate your thinking and catch blind spots before implementation begins.
