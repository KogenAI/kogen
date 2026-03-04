---
description: Create iteration documentation by auto-detecting changes from git and context
---

# Create New Iteration Documentation

Create a comprehensive iteration file that documents the current work session by automatically detecting changes from git history and project context.

## Auto-Detection Strategy

1. **Generate timestamp**: Use `date -u +%Y-%m-%d_%H%M%SZ` for filename
2. **Detect area**: Analyze git changes to determine primary area
   - `lib/spitex/` → backend
   - `lib/spitex_web/` → ui
   - `docs/`, `*.md` → knowledge
   - `test/` → testing
   - `k8s/`, `Dockerfile`, `.github/` → deployment
3. **Detect human**: Use git config `user.name` or extract from recent commits
4. **Detect agent**: Auto-set to "claude" (or detect from MCP context if available)
5. **Detect status**:
   - Check if branch is clean → "merged"
   - Uncommitted changes → "in-progress"
   - Default → "merged" if on main
6. **Generate description**: Analyze git log and file changes to create concise summary

## Execution Steps

### 1. Gather Git Information

```bash
# Get recent commits (last 5)
git log -5 --oneline --no-merges

# Get changed files in recent commits
git diff --name-only HEAD~5..HEAD

# Get uncommitted changes
git status --short

# Get current branch
git branch --show-current

# Get user name
git config user.name
```

### 2. Analyze Changes

- **Count file types changed**:
  - Count `lib/spitex/*.ex` files → backend domain logic
  - Count `lib/spitex_web/*.ex` files → UI/LiveView
  - Count `test/*.exs` files → testing
  - Count `docs/*.md` files → knowledge/documentation
  - Count `k8s/*.yaml`, `Dockerfile` → deployment

- **Determine primary area**: The category with most changes

- **Extract description keywords** from:
  - Recent commit messages
  - Modified file names (e.g., `invite.ex` → "invite")
  - Function/module names in changes

### 3. Generate Metadata

- **Timestamp**: `$(date -u +%Y-%m-%d_%H%M%SZ)`
- **Area**: Primary area from analysis (backend/ui/knowledge/testing/deployment)
- **Human**: Extract from `git config user.name` → lowercase first name
- **Agent**: "claude"
- **Status**:
  - "merged" if on main branch with no uncommitted changes
  - "in-progress" if uncommitted changes exist
  - "merged" as default
- **Description**: Combine top 2-3 keywords from commits/files with hyphens

### 4. Create Iteration File

**IMPORTANT**: File location depends on status:

- **Active work** (`started`, `in-progress`, `tested_ok`, `pr_opened`, `pr_issues`):

  ```
  docs/iterations/{TIMESTAMP}_{area}_{human}_{agent}_{status}_{description}.md
  ```

- **Completed work** (`merged`, `finished`):
  ```
  docs/iterations/merged/{TIMESTAMP}_{area}_{human}_{agent}_{status}_{description}.md
  ```

**Organization Rules**:

- Merged/finished iterations go in `merged/` subdirectory to keep active work visible at root level
- **Flat structure**: All merged iterations in single directory (no month/year subfolders)
- Sorted naturally by filename timestamp (YYYY-MM-DD)

### 5. Fill Template

Copy from `docs/iterations/_iteration_template.md` and auto-fill:

- Metadata section (human, agent, started time, status)
- Files Modified (list from git diff)
- Recent commits (from git log)
- Technical Implementation (analyze modified files)
- Changelog (add creation timestamp)

### 6. Smart Content Generation

**For "Files Modified" section**:

```bash
# Get detailed file changes
git diff HEAD~5..HEAD --stat
```

List each file with:

- Full path
- Line count changed
- Brief description of what changed (analyze file type)

**For "Lifecycle Timeline"**:

- Parse recent commit timestamps
- Map commits to lifecycle stages (Started → In Progress → Merged)

**For "Tasks & Acceptance Criteria"**:

- Mark all tasks as completed (✅)
- Extract task names from commit messages
- Add file references with line numbers if available

### 7. Present to User

Show the generated file path and offer to open it for review:

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
- Location: docs/iterations/merged/ (completed) OR docs/iterations/ (active)
```

## Example Detection Logic

**Scenario**: Recent commits modified `lib/spitex/accounts/invite.ex`, `lib/spitex/accounts/changes/*.ex`

**Detection Results**:

- Area: `backend` (lib/spitex/ files)
- Human: `almir` (from git config)
- Agent: `claude`
- Status: `merged` (on main, clean working tree)
- Description: `fix-invite-anonymous-functions` (from commit message and file names)

**Generated filename and location**:

```
docs/iterations/merged/2025-10-29_161033Z_backend_almir_claude_merged_fix-invite-anonymous-functions.md
```

(Note: File is in `merged/` subdirectory because status is `merged`)

## Edge Cases

- **Multiple areas changed**: Choose area with most file changes
- **No git history**: Use "in-progress" status and prompt for description
- **No commits yet**: Analyze uncommitted changes only
- **Generic commit messages**: Use file names to generate description
- **Long description**: Limit to 5 words, use most relevant keywords

## Quality Checks

Before finalizing:

1. Verify filename follows convention
2. Ensure all required metadata fields populated
3. Check that Files Modified section lists actual changes
4. Validate timestamp format
5. Confirm iteration file doesn't already exist
6. **Verify correct directory**:
   - `merged` status → `docs/iterations/merged/`
   - `in-progress` or other active status → `docs/iterations/`
