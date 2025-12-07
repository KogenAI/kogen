# Compress Rules - Actual Implementation

## Task Overview

You are executing the compress-rules command. Systematically compress ALL rule files in `/Users/almirsarajcic/Areas/Optimum/context/rules` to reduce verbosity while preserving 100% of the knowledge content.

## CRITICAL: What You Must Do

**This is NOT just analysis - you must ACTUALLY compress the files.**

1. **Get baseline metrics**: Count current lines in all rule files
2. **Process each file systematically**: Read complete file, compress it, update original
3. **Clean up temporary files**: Remove any \*-compressed.md versions
4. **Generate final report**: Show before/after metrics

## Compression Principles

**📚 Style guide reference**: See `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` for:

- Visual marker usage standards
- Wording consistency guidelines
- Cross-role contamination prevention

**CRITICAL: Preserve ALL Knowledge**

- Every rule, pattern, gotcha, and discovery must be kept
- Every bash command, search strategy, and diagnostic sequence must be preserved
- Every "don't do this" warning and failure pattern must remain
- Every breakthrough insight and performance metric must be included
- **NEVER compress code that will appear in applications** (error messages, config examples, API responses)
- **NEVER compress examples that developers will copy-paste** (complete command examples, full code blocks)

**Compression Techniques:**

1. **Remove verbose explanations** - Convert paragraphs to bullet points
2. **Eliminate redundant examples** - One good example instead of multiple variations
3. **Cut excessive visual markers** - Remove unnecessary 🚨, ⚠️, etc.
4. **Consolidate repeated phrasing** - Remove wordy introductions
5. **Convert tutorial to reference format** - Action-focused, minimal context
6. **Preserve all commands verbatim** - Never modify bash commands or code examples

**NEVER Compress These:**

- **Error messages** that will appear in applications (raise "Missing DATABASE_URL...")
- **Configuration examples** that developers copy-paste (entire config blocks)
- **Complete command examples** (full bash commands with all flags)
- **API responses and data structures** that show expected formats
- **Code templates** that are meant to be copied exactly
- **Reference data and IDs** (Figma node IDs, database IDs, API keys, URLs)
- **Precise technical specifications** (port numbers, file paths, version numbers)
- **Copy-paste code blocks** that appear in final applications
- **Critical identifiers** that are used for lookups or integration

## MANDATORY Implementation Steps

### Step 1: Get Baseline Metrics

```bash
cd /Users/almirsarajcic/Areas/Optimum/context
echo "=== BEFORE COMPRESSION ==="
wc -l rules/**/*.md | sort -nr
echo "=== FILES TO PROCESS ==="
find rules -name "*.md" -type f | wc -l
```

### Step 2: Process Each File (DO THIS)

**For EACH .md file in rules directory:**

1. **Read complete file** (no partial reads!)
2. **Compress using principles above**
3. **Update original file** with compressed version
4. **Verify no knowledge loss**

**Process files by size (largest first) using:**

```bash
wc -l rules/**/*.md | sort -nr | head -10
```

**Target the biggest files first**: feature-tests.md, deployment.md, phoenix.md, testing.md, code-review.md

### Step 2b: INDEX.md Special Handling

INDEX.md (600+ lines) has repetitive per-agent sections. Convert to compact table format:

**Before** (verbose structure repeated 12x for each agent):

```markdown
### feature-developer

**Load in this exact order:**

1. **Shared rules** (ALWAYS):
   - `shared/subagent-core-rules.md`
   - `shared/server-management.md`
2. **Core domain rules** (🚨 ALWAYS CRITICAL):
   - `subagents/tdd.md`
   - `subagents/phoenix.md`
   - `subagents/elixir-code-generation.md`
3. **Standard domain rules** (ALWAYS load):
   - `subagents/workflow.md`
   - `subagents/git.md`
4. **Conditional domain rules** (load when task requires):
   - `subagents/testing.md`
5. **NEVER load** (reserved for other roles):
   - ❌ `code-review.md`
```

**After** (compact table - state shared rules once, then table for all agents):

```markdown
## Agent Rule Loading

**ALL agents load shared rules first:**

- `shared/subagent-core-rules.md`
- `shared/server-management.md`

| Agent                 | Core (Critical)                      | Standard                                      | Conditional                              | Never Load                         |
| --------------------- | ------------------------------------ | --------------------------------------------- | ---------------------------------------- | ---------------------------------- |
| feature-developer     | tdd, phoenix, elixir-code-generation | workflow, git                                 | testing, feature-tests, cucumber-bdd     | code-review, verification-workflow |
| verification-engineer | verification-workflow                | testing, elixir-ci, github-actions, git       | javascript-testing, poc-success-criteria | code-review, tdd                   |
| code-reviewer         | code-review, poc-success-criteria    | phoenix, elixir-code-generation, testing, git | ast-grep-patterns                        | verification-workflow, tdd         |
| ...                   | ...                                  | ...                                           | ...                                      | ...                                |
```

**Why**: Reduces INDEX.md from ~600 lines to ~150 lines while preserving 100% of the information.

### Step 3: Clean Up Temporary Files

```bash
# Remove any temporary compressed versions
find rules -name "*-compressed.md" -delete
find rules -name "*-dense.md" -delete
find rules -name "*-ultra-compressed.md" -delete
```

### Step 4: Generate Final Report

```bash
echo "=== AFTER COMPRESSION ==="
wc -l rules/**/*.md | sort -nr
echo "=== TOTAL REDUCTION ==="
# Compare before/after totals
```

## Critical Examples - What NOT to Compress

### ❌ WRONG: Compressing Reference Data

```markdown
# Before (correct)

Figma node IDs: 3389-24055, 3413-20318, 3668-46977

# After (WRONG - lost critical reference data)

Figma node IDs available in design files
```

### ❌ WRONG: Compressing Error Messages

```markdown
# Before (correct)

raise "Missing DATABASE_URL configuration in environment"

# After (WRONG - developers need exact error text)

raise database configuration error
```

### ✅ RIGHT: Compressing Explanations Only

```markdown
# Before (verbose)

This is a critical breakthrough discovery that we made on 2025-08-12 after spending hours debugging. The problem is that text assertions fail because of whitespace in HTML templates.

# After (compressed explanation, preserved facts)

**Problem**: Text assertions fail due to HTML whitespace.
```

## Expected Results

- Total rules system: ~8,000 lines → ~2,500-3,000 lines (60-70% reduction)
- Individual files: 60-80% size reduction
- 100% knowledge preservation
- All temporary files removed
- Improved usability and scanning speed

## SUCCESS CRITERIA

✅ **You have successfully completed this command when:**

1. All rule files (.md) have been compressed and updated
2. No temporary \*-compressed.md files remain
3. Total line count reduced by 60-70%
4. All knowledge preserved (commands, patterns, discoveries intact)
5. Final metrics report generated showing before/after

**DO THE WORK - Don't just analyze, ACTUALLY compress the files!**
