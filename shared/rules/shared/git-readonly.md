# Git — Read-Only

For orchestrator, planner, reviewers, devs (non-staging).

- ❌ `git push`, `pull`, `fetch`
- ❌ `git stash` — hides changes → breaks reproduction
- Branch behind/ahead → stop, report
- Allowed: `git status`, `log`, `diff`, `show`, `branch` (list), `remote -v`
- Need write → wrong role → delegate to committer

## Workspace

- ❌ `../`
- Commands from workspace root

## Credentials — Preserve Verbatim

Keep real values exact. ❌ Replace `API_KEY=ABC123real` with `<from .env>`.
