---
description: Audit rule loading and find redundancies for a role
argument-hint: <role>
---

# Check Rules for Role

**Arguments**: `<role>` — one of: `orchestrator`, `phoenix-developer`, `static-site-developer`, `verification-engineer`, `code-reviewer`

## Phase 1: Load Role Definition

**If role is `orchestrator`**:

- Load `./codegen/templates/AGENTS-HYBRID.md`
- Load `./codegen/rules/orchestration/delegation-patterns.md`

**For subagent roles**:

- Load `./codegen/templates/shared/subagents/{role}.md.j2`

Also load:

- `./codegen/rules/INDEX.md`

## Phase 2: Identify Required Rules

From INDEX.md, find the section for this role and extract all rule files that should be loaded.

## Phase 3: Load All Required Rules

For each rule file identified:

1. **Check file exists** — report missing files immediately
2. **Load existing files completely** (no limit/offset)
3. Prepare for redundancy analysis

## Phase 4: Find Redundancies

Compare content across ALL loaded files (role definition + rules):

**Look for**:

1. Duplicate sections across files
2. Repeated code examples
3. Overlapping tables/matrices
4. Redundant anti-patterns
5. Same workflows described in multiple places

**For each redundancy**:

```
### Redundancy: [Topic]
- File A: [filename] lines X-Y (~N lines)
- File B: [filename] lines X-Y (~N lines)
- Recommendation: Keep in [preferred file], reference from others
- Estimated savings: ~N lines
```

## Phase 5: Generate Fixes

- Consolidate duplicates to single source of truth
- Replace duplicates with references: `**See**: filename.md § Section`
- Follow `STYLE_GUIDE.md` compression principles

**Apply fixes directly** — don't just suggest, actually edit the files.

## Phase 6: Report Summary

```
## Check Rules Summary: {role}

### Required Rules (from INDEX.md)
- [x] rule.md - EXISTS
- [ ] missing-rule.md - NOT FOUND

### Redundancies Found
- N redundancies across M files
- Estimated savings: ~Y lines

### Fixes Applied
1. [File]: [change]

### Before/After
| Metric | Before | After | Saved |
|--------|--------|-------|-------|
| Total lines | X | Y | Z (N%) |
```
