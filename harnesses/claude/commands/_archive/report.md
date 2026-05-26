---
description: Save work context (issues, progress, findings) for session handoff
argument-hint: [optional description]
---

Save current work context so future session can continue. Handles issues, research findings, design decisions, remaining work.

**DOCUMENTATION ONLY — NO CODE CHANGES**

Execute ALL steps in SINGLE response — do NOT wait for user confirmation.

## Steps

1. **Analyze conversation exhaustively** to extract:
   - Design decisions made
   - Research findings / investigation results
   - Issues discovered (bugs, blockers)
   - Remaining work / todos
   - Files modified or relevant
   - User questions (even casual ones)
   - User observations (anything mentioned, even in passing)

   DISTINGUISH resolved vs remaining:
   - Questions answered this session → do NOT create context files (already resolved)
   - Concerns addressed this session → do NOT create context files (already handled)
   - Actual remaining work → create context files ONLY for these

   Example: User asks "were there hallucinations?" and you answered "no" → RESOLVED, not pending. Only create context files for actual remaining work.

2. **Read CONTEXT.md** to understand current state

3. **Check for existing PENDING files first**:

   ALWAYS use RELATIVE paths:

   ```bash
   # CORRECT - relative path (works in any workspace)
   ls ./codegen/context/PENDING-* 2>/dev/null

   # WRONG - absolute path (writes to wrong location!)
   # /Users/.../bemeda_personal/codegen/context/PENDING-*
   ```

   Why: Workspaces are git worktrees with their own `./codegen/context/`. Absolute paths → writes to MAIN project → invisible to orchestrator.

   If relevant PENDING files exist for same topic:
   - UPDATE existing file instead of creating new one
   - Add findings to existing sections
   - Update remaining work checklist
   - Add "Updated: [timestamp]" to file header

   Create NEW files only when:
   - No existing PENDING file covers topic
   - Issue completely separate from existing pending work
   - Need to split large file into smaller focused issues

4. **Create/Update context files** in `./codegen/context/`:
   - Multiple distinct issues → separate files for each
   - Individual issue files: `PENDING-issue-{timestamp}-{short-description}.md`
   - Summary file (optional): `PENDING-{topic}-{timestamp}.md`
   - Each file independently actionable

   Naming:
   - Unresolved work → `PENDING-issue-{timestamp}-{description}.md`
   - Resolved this session → `RESOLVED-{timestamp}-{description}.md`

   Create RESOLVED files to preserve knowledge. Future sessions can reference but won't work on them.

5. **Update CONTEXT.md**:
   - Add ALL issues to CURRENT ISSUES or BLOCKING ISSUES
   - ALL items must be worked on — don't suggest any are "low priority"
   - Add decisions to DECISIONS section (create if needed)
   - Update PROGRESS or STATUS sections

6. **Verify — cross-check against conversation**:

   Re-read all user messages and verify:
   - Every unresolved issue has context file
   - Questions answered this session marked RESOLVED
   - Numbered checklist distinguishing:
     - RESOLVED this session (no context file)
     - PENDING for next session (has context file)

7. **Present final summary**:

   ```
   Context saved for handoff:

   CONTEXT.md Updated:
   - [what was added/updated]

   Context Files Created/Updated:
   - `./codegen/context/PENDING-issue-...` - [description] (CREATED|UPDATED)

   Ready to close session - run `ocg resume` to continue

   Add anything I missed?
   ```

## Context File Templates

### Individual Issue File

```markdown
# Issue: [Short Description]

**Created**: [timestamp]
**Status**: PENDING
**Priority**: CRITICAL | HIGH | MEDIUM | LOW
**Devices/Environment**: [relevant context]

## Summary

[1-2 sentence description]

## User Report

> "[Exact quote from user if available]"

## Expected Behavior

[What should happen]

## Impact

- [Specific impact on users/system]

## Root Cause Analysis

[Analysis of potential causes]

## Relevant Files

- `path/to/file.ex:123` - [what this file/line does]

## Remaining Work

- [ ] [Specific actionable task]

## Test Scenario

[Step-by-step reproduction]

## Visual Description from User Testing

Describe what you SAW in detail — NEVER reference "Image #1". Future sessions can't access images.

- "Small notification banner at top of screen with Accept/Decline buttons"
- "Chat interface showing empty message list with no call logs"

## Notes for Next Session

[Additional context for fixing this issue]
```

### UI Issue File

UI issues MUST include exact Tailwind specifications, not vague descriptions.

````markdown
# Issue: [UI Element] Styling Mismatch

**Created**: [timestamp]
**Status**: PENDING
**Priority**: CRITICAL | HIGH | MEDIUM | LOW
**Scope**: ui-specialist | feature-developer

## Summary

[1-2 sentence description]

## User Report

> "[Exact quote from user]"

## Exact Tailwind Specifications

### Issue 1: [Element Name]

**Current (Wrong):**

- [Current classes if known]

**Figma (Correct):**

- [Visual description]

**Exact Tailwind classes:**

```html
<element class="[exact classes to use]"> Content </element>
```
````

**Key classes:**

- `class-name` - what it does (e.g., "12px padding")

## Implementation Checklist

- [ ] Change [specific element] from `old-class` to `new-class`

## Relevant Files

- `path/to/template.html.heex` - [which component/section]

## Testing After Fix

1. Check mobile (375px) - [what to verify]
2. Check desktop (1280px) - [what to verify]

````

### Resolved File

```markdown
# Resolved: [Short Description]

**Created**: [timestamp]
**Status**: RESOLVED
**Resolved By**: [investigation/decision/fix applied this session]

## Question/Concern

> "[Original user question or concern]"

## Investigation

[What was checked/analyzed]

## Resolution

[What was found/decided/answered]

## Key Findings

- [Important fact discovered]

## Relevant Files

- `path/to/file.ex` - [relevance]
````

### Summary File (optional)

```markdown
# [Topic/Feature Name]

**Created**: [timestamp]
**Status**: PENDING - Ready for next session

## Summary

[Brief description of what was being worked on]

## Issues Found

- `PENDING-issue-{timestamp}-{issue-1}.md` - [Short description]

## Decisions Made

- [Decision 1]: [Rationale]

## Remaining Work

- [ ] Fix issue #1 (see issue file)

## Relevant Files

- `path/to/file.ex` - [what it does]

## Notes for Next Session

[Overall context, not issue-specific]
```

## Output Format

```
Context saved for handoff:

CONTEXT.md Updated:
- [what was added/updated]

Context Files Created:
- `./codegen/context/PENDING-issue-{timestamp}-{issue-1}.md` - [description]

Verification Checklist:
| # | User Reported | Resolution | Status |
|---|---------------|------------|--------|
| 1 | [question] | `RESOLVED-...` (knowledge preserved) | RESOLVED |
| 2 | [remaining work] | `PENDING-issue-...` | PENDING |

Total: X items, Y resolved, Z pending

Ready to close session - run `ocg resume` to continue
```

## DO NOT

- Make code changes
- Implement fixes
- Modify source files
- Delete existing context files — NEVER remove RESOLVED or PENDING files. Contains valuable knowledge. If PENDING issue is resolved, rename to RESOLVED or create new RESOLVED file.
- Invent solutions — don't make up "use PubSub" or "wrap in form tag". Not a specialist.
- Hallucinate or assume details — if you don't know something (e.g., which platform error came from), ASK or note uncertainty.

## DO ONLY

- Extract and document context
- Update CONTEXT.md
- Create context files for handoff
- Describe problems clearly — what's broken, what user expected, what actually happens
- Document symptoms — error messages, user quotes, visual descriptions
- Describe screenshots in detail — NEVER reference as "Image #1". Future sessions can't access images. Describe: "Small notification banner at top of screen showing caller name"
- Include user suggestions verbatim — user has domain knowledge, their suggestions should guide impl
- Leave solutions to specialists — unless user provided guidance, let subagents determine fix
