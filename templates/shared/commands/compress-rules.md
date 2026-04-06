---
description: Compress all rule files to reduce token usage while preserving knowledge
argument-hint:
---

# Compress Rules

Systematically compress ALL rule files in the context rules directory.

## Process

### Step 1: Baseline Metrics

```bash
cd ~/Areas/Optimum/context/rules
wc -l **/*.md *.md | sort -nr
```

### Step 2: Compress Each File (largest first)

For EACH .md file:

1. Read complete file
2. Apply compression principles from `STYLE_GUIDE.md`
3. Update original file
4. Verify no knowledge loss

### Compression Principles

**Read `~/Areas/Optimum/context/rules/STYLE_GUIDE.md` for full guidelines.** Key points:

- Lead with rule, not rationale
- One example per pattern (bad → good), never three
- No preambles or restating
- Tables over prose
- Reference shared content, don't duplicate

**NEVER compress**:

- Error messages in application code
- Configuration examples developers copy-paste
- Complete command examples with flags
- Code templates meant to be copied
- Reference data (IDs, URLs, port numbers, paths)

**DO compress**:

- Verbose explanations → bullet points
- Redundant examples → single representative example
- Excessive visual markers (🚨, ⚠️)
- Tutorial-style prose → reference format
- Dead role references (only 3 active roles: feature-developer, verification-engineer, code-reviewer)

### Step 3: Clean Up

```bash
find rules -name "*-compressed.md" -delete
find rules -name "*-dense.md" -delete
```

### Step 4: Final Report

```bash
wc -l **/*.md *.md | sort -nr
```

## Target Metrics

| File type           | Target           |
| ------------------- | ---------------- |
| Shared rules        | < 50 lines each  |
| Subagent rules      | < 300 lines each |
| Orchestration rules | < 150 lines each |

## Success Criteria

1. All rule files compressed and updated
2. No temporary files remain
3. All knowledge preserved (commands, patterns, discoveries intact)
4. Final metrics report generated
