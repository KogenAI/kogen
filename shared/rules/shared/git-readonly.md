# Git — Read-Only

For orchestrator, planner, reviewers, devs (non-staging).

- ❌ `git push`, `pull`, `fetch`
- ❌ `git stash` — hides changes → breaks reproduction
- ❌ `git add`, `git rm`, `git mv`, `git restore --staged` — staging/index writes → committer owns staging
- ❌ `git commit`, `rebase`, `cherry-pick`, `revert`, `merge`, `reset --hard` — history-mutating → committer owns history
- Branch behind/ahead → stop, report
- Allowed: `git status`, `log`, `diff`, `show`, `branch` (list), `remote -v`
- Need write → **under the loop**: do not stage or commit — leave changes in the working tree, the loop's committer step runs after you; finish your remaining in-role work and stop. **Interactive orchestrator** (holds the Agent tool): delegate to the committer subagent.

## Workspace

- ❌ `../`
- Commands from workspace root

## Credentials — Preserve Verbatim

Keep real values exact. ❌ Replace `API_KEY=ABC123real` with `<from .env>`.
