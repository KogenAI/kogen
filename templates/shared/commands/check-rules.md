---
description: Audit rule loading and find redundancies for a role
argument-hint: <role> [log-file-path]
---

# Check Rules for Role

**Arguments**:

- `<role>` (e.g., ui-specialist, orchestrator, feature-developer, planner)
- `[log-file-path]` (optional - session log to verify; skip for planner role)

## Phase 1: Load Role Definition

**If role is `orchestrator`**:

- Load `./codegen/templates/NEW_PROMPT.md`
- Load `./codegen/templates/RESUME_PROMPT.md`

**If role is `planner`**:

- Load `./codegen/templates/planning-sessions/detailed-planning/SESSION_CONTEXT.md`
- Load `./codegen/templates/planning-sessions/bird-eye/SESSION_CONTEXT.md`
- Also check for PoC planning variant (if exists): `./codegen/rules/planning-poc.md`

**For all other roles**:

- Load `./codegen/templates/shared/subagents/{role}.md.j2`

Also load:

- `./codegen/templates/AGENTS.md`
- `./codegen/rules/INDEX.md` (or `$OCG_CONTEXT_DIR/rules/INDEX.md`)

## Phase 2: Identify Required Rules

From INDEX.md, find the section for this role (e.g., `### ui-specialist`) and extract all rule files that should be loaded.

**For orchestrator**, this includes:

- All shared rules
- All orchestration rules

**For planner**, check BOTH SESSION_CONTEXT.md AND INDEX.md:

1. **From SESSION_CONTEXT.md** (what planner is told to load):
   - `./codegen/rules/planning.md` - Always required
   - Domain-specific rules (phoenix.md, flutter.md, ui-implementation.md, etc.) based on feature type

2. **From INDEX.md** (cross-reference):
   - Check `## 🎯 STANDALONE RULES` section for `planning.md` entry
   - Verify all domain rules mentioned in SESSION_CONTEXT.md are listed in INDEX.md
   - Check if INDEX.md mentions planning-related rules not in SESSION_CONTEXT.md

3. **Compare and identify gaps**:
   - Rules in SESSION_CONTEXT.md but NOT in INDEX.md → INDEX.md incomplete
   - Rules in INDEX.md planning section but NOT in SESSION_CONTEXT.md → SESSION_CONTEXT.md may be missing useful rules
   - **Note**: Bird-eye vs detailed planning may have different rule requirements

**For subagents**, this includes:

- Shared rules (subagent-core-rules.md, server-management.md)
- Core domain rules
- Standard domain rules
- Conditional domain rules (when applicable)

## Phase 3: Load All Required Rules

**CRITICAL: Verify files exist before loading**

For each rule file identified in Phase 2:

1. **Check file exists**: Use Read tool or `ls` to verify the file actually exists
2. **Report missing files**: If any required rule file doesn't exist, note it immediately
3. **Load existing files completely** (NO limit/offset) to:
   - Understand what each rule contains
   - Prepare for redundancy analysis

**For planner role specifically**:

- Verify all domain rules mentioned in SESSION_CONTEXT.md exist in `./codegen/rules/subagents/`
- Check that `planning.md` exists in `./codegen/rules/`
- Cross-check INDEX.md entries against actual filesystem

## Phase 4: Verify Rule Loading from Log

**If log file provided**, read the session log file and check:

1. **Rules & Context Loaded section**: Are all required rules marked `[x]`?
2. **Missing rules**: Which rules from INDEX.md or SESSION_CONTEXT.md are NOT checked in the log?
3. **Extra rules**: Which rules are loaded but NOT required?

**Report format**:

```
## Rule Loading Verification

### Required Rules (from INDEX.md or SESSION_CONTEXT.md)
- [x] shared/subagent-core-rules.md - LOADED
- [x] shared/server-management.md - LOADED
- [ ] subagents/ui-implementation.md - NOT LOADED
...

### Summary
- Total required: X
- Actually loaded: Y
- Missing: Z rules
```

**If NO log file provided** (e.g., for planner role):

Skip this phase and proceed directly to Phase 5 (redundancy check).

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

**For missing rules** (if log file was provided):

- Update role definition to be more explicit about required rules
- Add numbered list if currently vague

**For redundancies**:

- Consolidate duplicate content to single source of truth
- Replace duplicates with references like "See [file] for details"
- Trim verbose explanations

**Apply fixes directly** - don't just suggest, actually edit the files.

**For planner role specifically**:

- Check if planning rules (planning.md) are redundant with SESSION_CONTEXT.md
- Ensure domain rules referenced in SESSION_CONTEXT.md actually exist
- Verify that question guidelines are consistent between bird-eye and detailed planning
- **Update INDEX.md** if it's missing rules that SESSION_CONTEXT.md references
- **Update SESSION_CONTEXT.md** if INDEX.md has useful planning rules not mentioned

## Phase 7: Report Summary

```
## Check Rules Summary: {role}

### Rule Loading
- Required: X rules (from SESSION_CONTEXT.md or INDEX.md)
- Actually loaded: Y rules (if log file provided)
- Missing from log: Z rules (if log file provided - list them)
- **Missing from filesystem**: N rules (list them with expected paths)
- **Orphaned in INDEX.md**: M rules (listed in INDEX but don't exist)

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

### Planner-Specific Findings (if role is planner)
- Bird-eye vs Detailed: Are question guidelines consistent?
- SESSION_CONTEXT.md vs planning.md: Redundancy level (planning.md = shared, SESSION_CONTEXT = mode-specific)
- Domain rule references: All exist and are accessible?
- INDEX.md completeness: Are all SESSION_CONTEXT.md rules listed?
- SESSION_CONTEXT.md completeness: Are all relevant INDEX.md planning rules mentioned?
- Figma bootstrap: Is Figma workflow in detailed SESSION_CONTEXT.md ONLY (not in planning.md or bird-eye)?
- Hallucination checks: Are verification requirements consistent across files?
- TDD approach: Is TDD-first planning properly documented?
- AskUserQuestion categories: Are question categories aligned between bird-eye and detailed?
```

## Phase 8: Planner-Specific Deep Analysis (Only for planner role)

**Skip this phase for non-planner roles.**

### 8a. Compare Bird-Eye vs Detailed Planning

Check for alignment and appropriate differences:

| Aspect                     | Bird-Eye                              | Detailed                                                  | Should Match? |
| -------------------------- | ------------------------------------- | --------------------------------------------------------- | ------------- |
| Planning rules loaded      | planning.md only                      | planning.md + domain rules                                | ❌ Different  |
| Figma bootstrap            | Not required                          | MANDATORY Phase 0                                         | ❌ Different  |
| AskUserQuestion categories | Scope, Business, Constraints, Success | Implementation, Environment, Scope, Manual Steps, Testing | ⚠️ Review     |
| Hallucination check        | Project state verification            | Technical documentation verification                      | ⚠️ Review     |
| Output format              | Single file (30-50 lines)             | Modular structure (overview + steps)                      | ❌ Different  |
| Code examples              | None                                  | Detailed with patterns                                    | ❌ Different  |

**Flag misalignments**: If question categories or verification requirements are inconsistent, recommend consolidation.

### 8b. Check for Duplicated Content

Compare these specific sections between SESSION_CONTEXT.md files and planning.md:

1. **Figma bootstrap steps**: Should be in detailed SESSION_CONTEXT.md ONLY (not planning.md or bird-eye)
2. **Question guidelines**: What questions to ask (FORBIDDEN vs ALLOWED) - detailed SESSION_CONTEXT only
3. **Hallucination check process**: Verification steps - should be in planning.md (shared)
4. **Modular plan structure**: Directory/file conventions - should be in planning.md (shared)
5. **TDD-first planning**: Implementation + tests together - should be in planning.md (shared)

**Report duplications**:

```
### Duplication: [Section Name]
- Source A: SESSION_CONTEXT.md (detailed) lines X-Y
- Source B: planning.md lines X-Y
- Overlap: ~N% similar
- Recommendation: [Keep in one place, reference from other]
```

### 8c. Verify Domain Rule Mapping

For detailed planning, SESSION_CONTEXT.md says to load domain rules based on feature type:

```
- Phoenix/Elixir features → phoenix.md + elixir-code-generation.md
- Flutter/mobile features → flutter.md + mobile-testing.md
- UI/design features → ui-implementation.md + phoenix.md
- Testing features → testing.md + feature-tests.md
- Translation features → i18n.md
- CI/deployment features → github-actions.md + deployment.md
```

**Verify each rule file exists**:

```bash
ls ./codegen/rules/subagents/phoenix.md
ls ./codegen/rules/subagents/elixir-code-generation.md
ls ./codegen/rules/subagents/flutter.md
# ... etc
```

**Check INDEX.md lists these mappings** in a discoverable way.

### 8d. Check for Missing Cross-References

**SESSION_CONTEXT.md should reference**:

- `planning.md` for detailed planning rules
- INDEX.md for rule discovery
- AGENTS.md for universal patterns

**planning.md should reference**:

- INDEX.md for rule discovery
- SESSION_CONTEXT.md as the entry point for planning sessions

**INDEX.md should include**:

- `planning.md` in STANDALONE RULES section with keywords
- `planning-poc.md` in STANDALONE RULES section (if PoC planning exists)
- Clear note about when planning rules are used (planning sessions only)

### 8e. Check for FORBIDDEN Tool Usage Documentation

Both SESSION_CONTEXT.md files should clearly document:

1. **FORBIDDEN tools during planning**: Edit, MultiEdit, EnterPlanMode, ExitPlanMode
2. **ALLOWED tools**: Read, Grep, Glob, Task, Write (for plan files only), AskUserQuestion
3. **Why forbidden**: EnterPlanMode/ExitPlanMode are Claude Code built-in tools that conflict with OCG planning

**Verify this is documented consistently** in both bird-eye and detailed SESSION_CONTEXT.md files.

### 8f. Verify Bookend Pattern Documentation (Detailed Planning Only)

Detailed planning has a "bookend pattern" for manual steps:

```
MANUAL START → AUTONOMOUS MIDDLE → MANUAL END
```

**Check**:

- Is this pattern clearly explained?
- Are example questions aligned with identifying bookend steps?
- Is this pattern referenced in planning.md?
