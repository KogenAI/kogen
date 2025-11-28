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

   🚨 **ZERO TOLERANCE FOR SKIPPING**: Every single thing the user reported, asked about, or mentioned MUST be documented AND worked on. No exceptions. No "we can handle this later." No prioritization that results in items being dropped or deferred. If the user said it, document it AND it must be fixed/addressed in this work session. Priority labels are for ordering work, NOT for deciding what to skip.

2. **Read CONTEXT.md** to understand current state

3. **Create context files IMMEDIATELY** in `./codegen/context/`:

   - **IMPORTANT**: If multiple distinct issues found, create **separate files** for each issue
   - **Individual issue files**: `PENDING-issue-{timestamp}-{short-description}.md`
   - **Summary file** (optional): `PENDING-{topic}-{timestamp}.md` for overview
   - Each file should be independently actionable
   - Allows parallel work on different issues
   - Structure for easy pickup by next session

4. **Update CONTEXT.md** with relevant sections:

   - Add ALL issues to **CURRENT ISSUES** or **BLOCKING ISSUES**
   - **ALL items must be worked on** - don't suggest some are "for later" or "low priority can wait"
   - Add decisions to **DECISIONS** section (create if needed)
   - Update **PROGRESS** or **STATUS** sections

5. **VERIFY: Cross-check against conversation**:

   Before presenting the summary, re-read all user messages in the conversation and verify:

   - Every issue mentioned has a context file
   - Every question asked is addressed or documented
   - Every observation/complaint has been captured
   - Create a numbered checklist showing each user-reported item and its corresponding context file

6. **Present final summary** showing what was saved:

   ```
   ✅ Context saved for handoff:

   📋 **CONTEXT.md Updated**:
   - [what was added/updated]

   📁 **Context Files Created**:
   - `./codegen/context/PENDING-issue-...` - 🔥 [description]

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

## Notes for Next Session

[Additional context helpful for fixing this specific issue]
```

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

✅ **Verification Checklist** (user-reported → context file):
| # | User Reported | Context File | Status |
|---|---------------|--------------|--------|
| 1 | [issue/question] | `PENDING-issue-...` | ✅ |
| 2 | [issue/question] | `PENDING-issue-...` | ✅ |

**Total: X items reported, X documented, 0 skipped**

🔄 **Ready to close session - run `ocg resume` to continue**
```

**DO NOT**:

- Make code changes
- Implement fixes
- Modify source files
- **Invent solutions yourself** - Don't make up solutions like "use PubSub" or "wrap in form tag". You are an orchestrator, not a specialist.
- **Hallucinate or assume details** - If you don't know something (e.g., which platform an error came from), ASK or note uncertainty. Don't guess "browser console" when it might be Flutter logs. Wrong information will mislead agents trying to fix the issue.

**DO ONLY**:

- Extract and document context
- Update CONTEXT.md
- Create context files for handoff
- **Describe problems clearly** - What's broken, what user expected, what actually happens
- **Document symptoms** - Error messages, screenshots, user quotes
- **Include user suggestions verbatim** - If the user suggests a solution or approach (e.g., "can't you use endpoint.subscribe?"), include that in the context file. The user has domain knowledge and their suggestions should guide the implementation.
- **Leave solutions to specialists** - Unless the user provided guidance, let subagents determine the fix
