# Port Allocation — `resource_manager.sh`

Global, system-wide port allocator for OCG projects. NOT an install-artifact tracker (a stale claim
that lived in `repo-structure.md`/`core.md`/`PROJECT_CONTEXT.md` for a long time — `resource_manager.sh`
has zero references to `installed-by-ocg` or `manifest`, and `install.sh`/`uninstall.sh` never source
it).

## What It Owns

- `$HOME/.ocg/resources.json` — global registry: `phoenix_ports`, `playwright_ports`, `metadata.last_updated`.
- `$HOME/.ocg/resources.lock` — `mkdir`-based lock directory (atomic; `mkdir` fails if the dir already
  exists). `acquire_lock` polls up to 10s in 0.1s increments, `release_lock` does `rmdir`.
- Port allocation functions: `is_port_allocated`, port-search-and-claim loops for `phoenix_ports` and
  `playwright_ports` (checks both the registry AND `is_port_in_use` before claiming).
- Corrupted-registry recovery: `ensure_global_registry` validates JSON via `jq .`; on corruption, backs
  up to `resources.json.backup.$(date +%s)` and recreates a clean skeleton.

## Real Consumers (3, confirmed by grep)

- `harnesses/claude/hooks/worktree-create-phoenix.sh` — allocates a port when creating a worktree.
- `harnesses/claude/hooks/worktree-remove-phoenix.sh` — releases the port on worktree teardown.
- `harnesses/shared/worktree-lifecycle.sh` (`worktree_destroy`) — releases stale allocations during experiment cleanup. Supersedes the old `experiment-prune.sh` (folded verbatim).

`install.sh` and `uninstall.sh` do NOT source this script — zero references, confirmed by grep. Prior
docs describing it as "tracks the installed-by-ocg manifest to avoid orphaned artifacts" were wrong;
that's a different concern (`resource_manager.sh` never mentions `.installed-by-ocg`).

## Gotchas

- `$TARGET_REPO_PATH` unset → allocation functions may silently misattribute the port's `project`/
  `workspace` metadata fields. Callers MUST have this set before invoking allocate/release.
- The registry is genuinely untested — no test file exercises `resource_manager.sh` directly (prior
  coverage-inventory docs calling it "indirectly exercised" were unverified).

## Trigger Keywords

resource_manager, port allocation, ~/.ocg/resources.json, mkdir lock, worktree port, playwright port, phoenix port, global registry, TARGET_REPO_PATH
