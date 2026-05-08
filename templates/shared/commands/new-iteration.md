---
description: Create iteration documentation by auto-detecting changes from git and context
---

# Create New Iteration Documentation

Create iteration file documenting current work session by auto-detecting changes from git history.

## Auto-Detection Strategy

1. **Timestamp**: `date -u +%Y-%m-%d_%H%M%SZ`
2. **Area**: Analyze git changes:
   - `lib/spitex/` → backend
   - `lib/spitex_web/` → ui
   - `docs/`, `*.md` → knowledge
   - `test/` → testing
   - `k8s/`, `Dockerfile`, `.github/` → deployment
3. **Human**: `git config user.name`
4. **Agent**: "claude"
5. **Status**:
   - Clean branch → "merged"
   - Uncommitted changes → "in-progress"

## Execution Steps

### 1. Gather Git Information

```bash
git log -5 --oneline --no-merges
git diff --name-only HEAD~5..HEAD
git status --short
git branch --show-current
git config user.name
```

### 2. Analyze Changes

- Count `lib/spitex/*.ex` → backend domain logic
- Count `lib/spitex_web/*.ex` → UI/LiveView
- Count `test/*.exs` → testing
- Count `docs/*.md` → knowledge
- Count `k8s/*.yaml`, `Dockerfile` → deployment
- Primary area = category with most changes
- Description keywords from commit messages, modified file names

### 3. Generate Metadata

- **Timestamp**: `$(date -u +%Y-%m-%d_%H%M%SZ)`
- **Area**: Primary area
- **Human**: First name from git config
- **Agent**: "claude"
- **Status**: "merged" (on main, clean) or "in-progress" (uncommitted changes)
- **Description**: Top 2-3 keywords from commits/files with hyphens

### 4. Create Iteration File

- **Active work** (`started`, `in-progress`): `docs/iterations/{TIMESTAMP}_{area}_{human}_{agent}_{status}_{description}.md`
- **Completed** (`merged`, `finished`): `docs/iterations/merged/{TIMESTAMP}_{area}_{human}_{agent}_{status}_{description}.md`

All merged iterations in `merged/` subdirectory. Flat structure, sorted by timestamp.

### 5. Fill Template

Copy from `docs/iterations/_iteration_template.md` and auto-fill:

- Metadata (human, agent, started time, status)
- Files Modified (from git diff)
- Recent commits (from git log)
- Technical Implementation (analyze modified files)
- Changelog (add creation timestamp)

### 6. Smart Content Generation

```bash
git diff HEAD~5..HEAD --stat
```

List each file with path, line count changed, and description.

### 7. Present to User

```
Created iteration file:
docs/iterations/[merged/]{TIMESTAMP}_{area}_{human}_{agent}_{status}_{description}.md

Auto-detected:
- Area: {area}
- Human: {human}
- Agent: claude
- Status: {status}
- Description: {description}
- Files changed: {count}
- Commits analyzed: {count}
```

## Edge Cases

- **Multiple areas**: Choose area with most file changes
- **No git history**: Use "in-progress", prompt for description
- **Generic commit messages**: Use file names for description

## Quality Checks

1. Filename follows convention
2. All required metadata populated
3. Files Modified lists actual changes
4. Timestamp format valid
5. File doesn't already exist
6. Correct directory (merged vs root)
