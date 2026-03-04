---
description: Save work context (issues, progress, findings) for session handoff
argument-hint: [optional description]
---

Save current work context so a future session can continue where you left off. Handles issues, research findings, design decisions, and remaining work.

**🚨 CRITICAL: DOCUMENTATION ONLY - NO CODE CHANGES**

**Workflow:**

🚨 **IMPORTANT: Execute ALL steps in a SINGLE response - do NOT wait for user confirmation**

1. **Analyze conversation EXHAUSTIVELY** to extract:
   - Design decisions made
   - Research findings / investigation results
   - Issues discovered (bugs, blockers)
   - Remaining work items / todos
   - Files modified or relevant to the work
   - **User questions** (even casual ones like "what is this X thing?")
   - **User observations** (anything the user mentioned, even in passing)

   🚨 **DISTINGUISH: Resolved vs Remaining**:
   - **Questions answered this session** → Do NOT create context files (already resolved)
   - **Concerns addressed this session** → Do NOT create context files (already handled)
   - **Actual remaining work** → Create context files ONLY for these

   Example: User asks "were there hallucinations?" and you investigated and answered "no" → This is RESOLVED, not a pending issue. Only create context files for actual remaining work items.

2. **Read CONTEXT.md** to understand current state

3. **🚨 CHECK FOR EXISTING PENDING FILES FIRST**:

   **CRITICAL: Always use RELATIVE paths for context files!**

   ```bash
   # ✅ CORRECT - relative path (works in any workspace)
   ls ./codegen/context/PENDING-* 2>/dev/null

   # ❌ WRONG - absolute path (writes to wrong location!)
   # /Users/.../bemeda_personal/codegen/context/PENDING-*
   ```

   **Why:** Workspaces are git worktrees with their OWN `./codegen/context/` directory.
   Using absolute paths writes to the MAIN project, making files INVISIBLE to the orchestrator.

   **If relevant PENDING files exist for the same topic/feature:**
   - **UPDATE the existing file** instead of creating a new one
   - Add new findings to existing sections
   - Update remaining work checklist
   - Add "Updated: [timestamp]" to the file header

   **Only create NEW files when:**
   - No existing PENDING file covers this topic
   - The issue is completely separate from existing pending work
   - You need to split a large file into smaller, focused issues

4. **Create/Update context files** in `./codegen/context/`:
   - **IMPORTANT**: If multiple distinct issues found, create **separate files** for each issue
   - **Individual issue files**: `PENDING-issue-{timestamp}-{short-description}.md`
   - **Summary file** (optional): `PENDING-{topic}-{timestamp}.md` for overview
   - Each file should be independently actionable
   - Allows parallel work on different issues
   - Structure for easy pickup by next session

   🚨 **RESOLVED vs PENDING file naming**:
   - **Unresolved work** → `PENDING-issue-{timestamp}-{description}.md`
   - **Resolved this session** → `RESOLVED-{timestamp}-{description}.md`

   Create RESOLVED files to preserve knowledge from investigations/decisions made this session. Future sessions can reference them but won't try to work on them.

5. **Update CONTEXT.md** with relevant sections:
   - Add ALL issues to **CURRENT ISSUES** or **BLOCKING ISSUES**
   - **ALL items must be worked on** - don't suggest some are "for later" or "low priority can wait"
   - Add decisions to **DECISIONS** section (create if needed)
   - Update **PROGRESS** or **STATUS** sections

6. **VERIFY: Cross-check against conversation**:

   Before presenting the summary, re-read all user messages in the conversation and verify:
   - Every **unresolved** issue has a context file
   - Questions answered this session are marked as RESOLVED (no context file needed)
   - Create a numbered checklist distinguishing:
     - ✅ RESOLVED this session (no context file)
     - 📁 PENDING for next session (has context file)

7. **Present final summary** showing what was saved:

   ```
   ✅ Context saved for handoff:

   📋 **CONTEXT.md Updated**:
   - [what was added/updated]

   📁 **Context Files Created/Updated**:
   - `./codegen/context/PENDING-issue-...` - 🔥 [description] (CREATED|UPDATED)

   🔄 **Ready to close session - run `ocg resume` to continue**

   Add anything I missed?
   ```

**Context File Templates:**

### Individual Issue File Template:

```markdown
# Issue: [Short Description]

**Created**: [timestamp]
**Status**: PENDING
**Priority**: 🔥 CRITICAL | ⚠️ HIGH | ⚠️ MEDIUM | ℹ️ LOW
**Devices/Environment**: [relevant context]

## Summary

[1-2 sentence description of the issue]

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
- [ ] [Another task]

## Test Scenario

[Step-by-step reproduction]

## Visual Description from User Testing

[If user provided screenshots, describe what you SAW in detail - never just reference "Image #1"]

**Example:**

- "Small notification banner at top of screen with Accept/Decline buttons"
- "Chat interface showing empty message list with no call logs"
- "Active call screen with green answer button visible"

## Notes for Next Session

[Additional context helpful for fixing this specific issue]
```

### UI Issue File Template (for styling/visual issues):

**🚨 CRITICAL**: UI issues MUST include exact Tailwind specifications, not vague descriptions.

````markdown
# Issue: [UI Element] Styling Mismatch

**Created**: [timestamp]
**Status**: PENDING
**Priority**: 🔥 CRITICAL | ⚠️ HIGH | ⚠️ MEDIUM | ℹ️ LOW
**Scope**: ui-specialist | feature-developer

## Summary

[1-2 sentence description]

## User Report

> "[Exact quote from user]"

## Exact Tailwind Specifications

### Issue 1: [Element Name]

**Current (Wrong):**

- [What it currently looks like with current classes if known]

**Figma (Correct):**

- [Visual description]

**Exact Tailwind classes:**

```html
<element class="[exact classes to use]"> Content </element>
```
````

**Key classes:**

- `class-name` - what it does (e.g., "12px padding")
- `class-name` - what it does

### Issue 2: [Next Element]

[Same format...]

## Implementation Checklist

- [ ] Change [specific element] from `old-class` to `new-class`
- [ ] Add [specific classes] to [element]
- [ ] Remove `class` from [element]

## Relevant Files

- `path/to/template.html.heex` - [which component/section]

## Testing After Fix

1. Check mobile (375px) - [what to verify]
2. Check desktop (1280px) - [what to verify]

````

### ❌ BAD UI Issue Documentation (Too Vague):

```markdown
## Issues:
- Status color is wrong
- Needs more padding
- Font should be lighter
- Make it look like the design
````

### ✅ GOOD UI Issue Documentation (Exact Specs):

````markdown
## Exact Tailwind Specifications

### Issue 1: Status Badge - Wrong Color

**Current:** `text-orange-500` (orange text, no background)
**Figma:** Purple pill with light background

**Exact Tailwind classes:**

```html
<span
  class="px-3 py-1 rounded-full text-sm font-normal text-violet-600 bg-violet-50"
>
  Sent
</span>
```
````

**Key classes:**

- `px-3 py-1` - 12px horizontal, 4px vertical padding
- `rounded-full` - pill shape
- `text-violet-600` - #7b4eab purple text
- `bg-violet-50` - #f2edf7 light purple background
- `font-normal` - weight 400 (remove existing bold)

## Implementation Checklist

- [ ] Change status from `text-orange-500` to `text-violet-600 bg-violet-50`
- [ ] Add `px-3 py-1 rounded-full` for pill shape
- [ ] Change `font-bold` to `font-normal`

````

### Resolved File Template (for preserving knowledge):

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
- [Decision made and rationale]

## Relevant Files

- `path/to/file.ex` - [relevance]
````

### Summary File Template (optional):

```markdown
# [Topic/Feature Name]

**Created**: [timestamp]
**Status**: PENDING - Ready for next session

## Summary

[Brief description of what was being worked on]

## Issues Found

See individual issue files:

- `PENDING-issue-{timestamp}-{issue-1}.md` - 🔥 [Short description]
- `PENDING-issue-{timestamp}-{issue-2}.md` - ⚠️ [Short description]

## Decisions Made

- [Decision 1]: [Rationale]

## Findings

- [Finding 1]

## Remaining Work

- [ ] Fix issue #1 (see issue file)
- [ ] Fix issue #2 (see issue file)

## Relevant Files

- `path/to/file.ex` - [what it does]

## Notes for Next Session

[Overall context, not issue-specific]
```

**Output Format:**

```
✅ Context saved for handoff:

📋 **CONTEXT.md Updated**:
- [what was added/updated]

📁 **Context Files Created**:
- `./codegen/context/PENDING-issue-{timestamp}-{issue-1}.md` - 🔥 [description]
- `./codegen/context/PENDING-issue-{timestamp}-{issue-2}.md` - ⚠️ [description]
- `./codegen/context/PENDING-{topic}-{timestamp}.md` (summary, if created)

✅ **Verification Checklist**:
| # | User Reported | Resolution | Status |
|---|---------------|------------|--------|
| 1 | [question/concern] | `RESOLVED-...` (knowledge preserved) | ✅ RESOLVED |
| 2 | [actual remaining work] | `PENDING-issue-...` | 📁 PENDING |

**Total: X items, Y resolved (in RESOLVED- files), Z pending (in PENDING- files)**

🔄 **Ready to close session - run `ocg resume` to continue**
```

**DO NOT**:

- Make code changes
- Implement fixes
- Modify source files
- **Delete existing context files** - NEVER remove RESOLVED or PENDING files. They contain valuable knowledge. If a PENDING issue is now resolved, rename it to RESOLVED or create a new RESOLVED file - don't delete.
- **Invent solutions yourself** - Don't make up solutions like "use PubSub" or "wrap in form tag". You are an orchestrator, not a specialist.
- **Hallucinate or assume details** - If you don't know something (e.g., which platform an error came from), ASK or note uncertainty. Don't guess "browser console" when it might be Flutter logs. Wrong information will mislead agents trying to fix the issue.

**DO ONLY**:

- Extract and document context
- Update CONTEXT.md
- Create context files for handoff
- **Describe problems clearly** - What's broken, what user expected, what actually happens
- **Document symptoms** - Error messages, user quotes, visual descriptions
- **Describe screenshots in detail** - NEVER reference screenshots as "Image #1" or "see screenshot". Future sessions cannot access images. Instead, describe what you saw: "Small notification banner at top of screen showing caller name", "Chat interface with no call log entries visible", etc.
- **Include user suggestions verbatim** - If the user suggests a solution or approach (e.g., "can't you use endpoint.subscribe?"), include that in the context file. The user has domain knowledge and their suggestions should guide the implementation.
- **Leave solutions to specialists** - Unless the user provided guidance, let subagents determine the fix
