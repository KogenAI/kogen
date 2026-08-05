# Git — Read-Only

For orchestrator, reviewers, devs (non-staging).

- ❌ `git push`, `pull`, `fetch`
- ❌ `git stash` — hides changes → breaks reproduction
- ❌ `git add`, `git rm`, `git mv`, `git restore` (with or without `--staged`) — staging/index writes AND working-tree discards → committer owns staging
- ❌ `git checkout`, `git switch` — checkout of a path can DISCARD another role's uncommitted working-tree edits; branch switches belong to the committer
- ❌ `git clean` (without `-n`/`--dry-run`) — PERMANENTLY DELETES untracked files, including another role's uncommitted new files
- ❌ `git commit`, `rebase`, `cherry-pick`, `revert`, `merge`, `reset --hard`/`--merge`/`--keep` — history-mutating or working-tree-destroying → committer owns history
- Branch behind/ahead → stop, report
- Allowed: `git status`, `log`, `diff`, `show`, `branch` (list), `remote -v`, `git clean -n` (dry-run preview only)
- **To read committed content, use `git show HEAD:<path>`** — never `git checkout`/`git restore` to inspect a file; those can silently discard uncommitted edits (yours or another role's) instead of just reading.
- Need write → **under the loop**: do not stage or commit — leave changes in the working tree, the loop's committer step runs after you; finish your remaining in-role work and stop. **Interactive orchestrator** (holds the Agent tool): delegate to the committer subagent.

## Workspace

- ❌ `../`
- Commands from workspace root

## Credentials — Preserve Verbatim

Keep real values exact. ❌ Replace `API_KEY=ABC123real` with `<from .env>`.
