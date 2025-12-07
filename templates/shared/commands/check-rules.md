---
description: Audit rule loading and find redundancies for a role
argument-hint: <role> <log-file-path>
---

# Check Rules for Role

**Arguments**: `<role>` (e.g., ui-specialist, orchestrator, feature-developer) and `<log-file-path>` (session log to verify)

## Phase 1: Load Role Definition

**If role is `orchestrator`**:

- Load `./codegen/templates/NEW_PROMPT.md`
- Load `./codegen/templates/RESUME_PROMPT.md`

**For all other roles**:

- Load `./codegen/templates/shared/subagents/{role}.md.j2`

Also load:

- `./codegen/templates/AGENTS.md`
- `./codegen/rules/INDEX.md` (or `$OCG_CONTEXT_DIR/rules/INDEX.md`)

## Phase 2: Identify Required Rules

From INDEX.md, find the section for this role (e.g., `### ui-specialist`) and extract all rule files that should be loaded.

For orchestrator, this includes:

- All shared rules
- All orchestration rules

For subagents, this includes:

- Shared rules (subagent-core-rules.md, server-management.md)
- Core domain rules
- Standard domain rules
- Conditional domain rules (when applicable)

## Phase 3: Load All Required Rules

Read each rule file completely (NO limit/offset) to:

1. Understand what each rule contains
2. Prepare for redundancy analysis

## Phase 4: Verify Rule Loading from Log

Read the provided session log file and check:

1. **Rules & Context Loaded section**: Are all required rules marked `[x]`?
2. **Missing rules**: Which rules from INDEX.md are NOT checked in the log?
3. **Extra rules**: Which rules are loaded but NOT required?

**Report format**:

```
## Rule Loading Verification

### Required Rules (from INDEX.md)
- [x] shared/subagent-core-rules.md - LOADED
- [x] shared/server-management.md - LOADED
- [ ] subagents/ui-implementation.md - NOT LOADED
...

### Summary
- Total required: X
- Actually loaded: Y
- Missing: Z rules
```

## Phase 5: Find Redundancies

Compare content across ALL loaded files (role definition + AGENTS.md + all rules):

**Look for**:

1. **Duplicate sections**: Same content explained in multiple files
2. **Repeated code examples**: Same code snippets in different files
3. **Overlapping tables**: Similar tables/matrices in multiple places
4. **Redundant anti-patterns**: Same violations listed multiple times
5. **Repeated workflows**: Same step-by-step processes duplicated

**For each redundancy found, report**:

```
### Redundancy: [Topic]
- File A: [filename] lines X-Y (~N lines)
- File B: [filename] lines X-Y (~N lines)
- Content: [brief description]
- Recommendation: Keep in [preferred file], reference from others
- Estimated savings: ~N lines / ~N tokens
```

## Phase 6: Generate Fixes

**For missing rules**:

- Update role definition to be more explicit about required rules
- Add numbered list if currently vague

**For redundancies**:

- Consolidate duplicate content to single source of truth
- Replace duplicates with references like "See [file] for details"
- Trim verbose explanations

**Apply fixes directly** - don't just suggest, actually edit the files.

## Phase 7: Report Summary

```
## Check Rules Summary: {role}

### Rule Loading
- Required: X rules
- Loaded: Y rules
- Missing: Z rules (list them)

### Redundancies Found
- N redundancies across M files
- Total duplicate lines: ~X
- Estimated token savings: ~Y

### Fixes Applied
1. [File]: [change description]
2. [File]: [change description]
...

### Before/After
| Metric | Before | After | Saved |
|--------|--------|-------|-------|
| Total lines | X | Y | Z (N%) |
| Estimated tokens | X | Y | Z |
```
