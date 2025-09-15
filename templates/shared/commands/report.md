---
description: Report bugs/issues to CONTEXT.md and create issue context files
argument-hint: [issue description]
---

Report bugs or issues discovered during implementation by updating CONTEXT.md and creating detailed context files for tracking.

**🚨 CRITICAL: DOCUMENTATION ONLY - NO CODE CHANGES**

This command is for **reporting and documenting issues ONLY**. Do NOT attempt to implement fixes, make code changes, or modify any implementation files. Only update documentation files (CONTEXT.md and context files).

**Workflow:**

1. **Read CONTEXT.md** to understand current state and existing issues
2. **Analyze the issue** provided in the argument (UI bugs, test failures, implementation problems, etc.)
3. **DOCUMENTATION ONLY - Update CONTEXT.md** with new issue in appropriate section:
   - Add to **CURRENT ISSUES** section if it exists
   - Create **NEW UI ISSUES IDENTIFIED** section for UI problems
   - Add to **BLOCKING ISSUES** for critical problems
   - Include issue priority (🔥 CRITICAL, ⚠️ NEEDS FIX, ℹ️ MINOR)
4. **DOCUMENTATION ONLY - Create detailed context file** in `./codegen/context/` if issue needs dedicated tracking:
   - File format: `PENDING-issue-{timestamp}-{issue-type}.md`
   - Include full issue description, expected vs actual behavior, reproduction steps
   - Reference relevant files/components affected
5. **Report completion** with summary of what was documented

**Issue Categories:**

- **UI Issues**: Visual mismatches, styling problems, component behavior
- **Test Failures**: Failing tests, CI issues, verification problems
- **Implementation Bugs**: Logic errors, missing functionality, performance issues
- **Integration Issues**: API problems, service connectivity, external dependencies

**Output Format:**

```
✅ Issue reported successfully:

📋 **CONTEXT.md Updated**:
- Added [issue type] to [section name]
- Priority: [priority level]

📁 **Context File Created** (if applicable):
- `./codegen/context/PENDING-issue-{timestamp}-{type}.md`

🔄 **Ready for workflow restart**
```

**🚨 ABSOLUTE RULE: DOCUMENTATION ONLY**

**Do NOT**:

- Fix the issue or make any code changes
- Modify implementation files
- Update any source code
- Make edits to application logic

**DO ONLY**:

- Document the issue in CONTEXT.md
- Create context tracking files
- Report what was documented

This is a reporting tool, not an implementation tool. All fixes should be delegated through proper workflow channels.
