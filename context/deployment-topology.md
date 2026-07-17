# Deployment Topology

Where codegen runs, what the root path is per machine/OS, and the rules that follow from multi-location reality.

## Current Locations

| Location                              | OS    | Codegen root                            |
| ------------------------------------- | ----- | --------------------------------------- |
| production host A                     | Linux | `<OPERATOR_FILL: prod codegen root>`    |
| production host B                     | Linux | `<OPERATOR_FILL: staging codegen root>` |
| dashboard box (Hetzner CCX13, Ubuntu) | Linux | `~/apps/codegen`                        |
| operator Macs                         | macOS | `~/Areas/Optimum/codegen`               |

## Trajectory

Narrowing to the primary production hosts and the Hetzner dashboard box as the primary production locations. Operator Macs remain for local development. Expect the Linux locations to dominate in CI/CD and automated operations.

## Cardinal Rule

Root differs per machine AND OS — NOTHING hardcodes it. Every script that needs the repo root derives `CODEGEN_DIR` from its own location via `BASH_SOURCE`:

```bash
CODEGEN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

See `install.sh`, `uninstall.sh`, `update_ai_tools.sh` — all use this idiom in their shebang/`set` preamble (top of file). Launcher scripts installed to `~/bin/` or `/usr/local/bin/` are no longer physically adjacent to the repo root and use one of two derivation strategies depending on launcher type.

## Symlink Resolution Mechanics (Critical for `harnesses/` symlink traversal)

When `harnesses/` is symlinked from `$SCRIPT_DIR` (install target) back to the codegen repo root, path traversal via `..` is context-sensitive:

- **`cd symlink/..`** — resolves `..` relative to the symlink's LOCATION (not its target). If symlink is `~/bin/harnesses → /path/to/repo/harnesses`, then `cd ~/bin/harnesses/.. → ~/bin`, NOT `/path/to/repo`.
- **`cd -P symlink && cd ..`** — `-P` flag forces physical path resolution. Traversing the symlink target's real parent correctly. This is the portable pattern for symlink-aware launchers.

Non-build launchers (shape, refactor, debug, ops) that derive `CODEGEN_DIR` via the installed `harnesses/` symlink MUST use `cd -P` to avoid landing in `~/bin` instead of the repo root.

- **Build launchers** (`claude-build.sh`, `pi-build.sh`): resolve the `codegen-build` binary as a sibling of `$SCRIPT_DIR` (co-installed in the same directory). No repo-root walk needed.
- **Non-build launchers** (shape, refactor, debug, ops, etc.): 3-branch `CODEGEN_DIR` derivation:
  1. `OCG_CODEGEN_DIR` env override if set (escape hatch)
  2. Installed-flat: follow the `harnesses/` symlink from `$SCRIPT_DIR` to derive the repo root
  3. In-repo checkout fallback: `$SCRIPT_DIR/../..`
- **`dispatch.sh`**: derives repo root via `$(cd "$SCRIPT_DIR/../.." && pwd -P)`, walking the physical path of the installed `harnesses/` symlink.

## Install Targets vs Source Location

| Artifact type | Install target                | Source                                       |
| ------------- | ----------------------------- | -------------------------------------------- |
| Agent prompts | `~/.claude/agents/*.md`       | `shared/subagents/*.md.j2`                   |
| Hook scripts  | `~/.claude/hooks/*.sh`        | `harnesses/claude/hooks/`                    |
| Settings      | `~/.claude/settings.json`     | `harnesses/claude/claude-code-settings.json` |
| Launchers     | `~/bin/` or `/usr/local/bin/` | `harnesses/claude/`, `harnesses/pi/`         |
| Pi extensions | `~/.pi/`                      | `harnesses/pi/pi-extensions/`                |

`~/.claude/`, `~/.pi/`, `/usr/local/bin/` (or `~/bin/`) are install TARGETS — where `make install` writes artifacts. They are NOT where source lives. Source lives in the codegen repo root (which differs per machine).

## OCG_CODEGEN_DIR Override

`OCG_CODEGEN_DIR` is an escape-hatch environment variable for edge cases — e.g., when a launcher script is symlinked to a location that cannot resolve back to the repo root, or in CI environments where the repo is checked out at a non-standard path. Set it in your shell profile:

```bash
export OCG_CODEGEN_DIR=/path/to/codegen   # override only when BASH_SOURCE derivation is unavailable
```

`OCG_CODEGEN_DIR` is NOT the primary mechanism. `BASH_SOURCE` derivation is primary (used by `install.sh`, `uninstall.sh`, `update_ai_tools.sh`). For non-build launchers, `OCG_CODEGEN_DIR` is branch 1 of 3 in the `CODEGEN_DIR` derivation; if unset the launcher walks the `harnesses/` symlink (branch 2) or falls back to `$SCRIPT_DIR/../..` (branch 3). Build launchers (`claude-build.sh`, `pi-build.sh`) do not need it — they resolve the `codegen-build` sibling binary directly from `$SCRIPT_DIR`.

Cross-reference: `shared/rules/shared/shell-script-discipline.md` — "Derive Root, Never Hardcode" section.

## Three-Repo Coordination Ordering

Order: context → codegen → platform. Deploy docs show actual SSH invocations verbatim, not prose. Each repo committed before next. ❌ Bundle changes across repos in prose ✅ Numbered SSH/git commands.

## Multi-Node Fleet Drain — Possession Discipline

`codegen-drain` (`codegen-drain assign|status|init`) dispatches pitches from `codegen/pitches/ready/` between fleet nodes when running `--watch` on more than one box. Its whole design rests on one invariant: **exactly one copy of a pitch exists across the fleet at any time.** Dispatch is `mv` — transfer, then delete the source only after the destination is checksum-verified — never `cp`. There is no lease, no TTL, no heartbeat: the failure mode a lease has (a dead box leaves a stale claim behind) has no analogue here, because there is no claim object, only a file that is somewhere.

Inventory lives at `codegen/drain-nodes.yaml` (gitignored — machine-local topology, same posture as `<app>/codegen/manifest.yaml`). Each node entry: `name`, `repo` (absolute path on that node), optional `host` (ssh target; omit for the local node), optional `run_as` (see below), optional `launch` (descriptive only — `codegen-drain` never starts a watcher on any node).

**ssh-lands-as-root discipline.** Some fleet hosts land an interactive `ssh` session as `root` even though the actual repo is owned by a dedicated service user (e.g. `studio`). A plain `scp`/`ssh` write in that situation creates a **root-owned file inside a non-root-owned repo** — it looks harmless (the pitch still builds; `mv` only needs directory permission) until `LoopQueue.record_ship/4` tries to write the ship record **into the pitch file itself** and hits `EACCES`, raising and refusing the ship. The pitch is then stuck in `ready/` with its work already landed — a corpse manufactured by a `chown` bit, not a code bug.

`codegen-drain` avoids this by staging every remote transfer through `/tmp` (root-writable, harmless), then using `install -o <run_as> -g <run_as>` to land the file inside `codegen/pitches/.incoming/` with the CORRECT ownership before it ever enters the tracked repo tree, then `su - <run_as> -c 'mv ...'` for the final same-filesystem move into `ready/`. Nodes with no `run_as` in the inventory (the ssh user already owns the repo) skip the `install -o` step — there is no ownership boundary to cross.

**Why the transfer never uses `scp -p`.** The `--watch` engine's quiescence gate (`quiescence_exclude/1` in `loop_queue_drain.ex`) treats a file as "still arriving" when `mtime > cutoff` — i.e. a recent mtime is what excludes a file from being selected mid-transfer. `scp -p` preserves the SOURCE mtime on the destination, which would make a freshly-arrived file read as "already old" and thus immediately eligible for build selection while bytes might still be incomplete on a slower path. `codegen-drain` never passes `-p` to `scp`; the final landing step is always a same-filesystem `mv`, which (per the engine's own moduledoc) is "already-quiescent the instant it lands" regardless of the mtime it carries.

**`codegen-drain status`'s `watcher=` column reads the lock file, never argv.** Earlier versions resolved `watcher=yes/no` via `pgrep -f "mix codegen.loop.*--cwd=$repo"` — an argv-scanning liveness probe that matches ANY process whose commandline happens to quote the search pattern, not only a real watcher. Verified live: a solo `mix codegen.loop --cwd=<repo>` build (`dispatch.sh`'s one-shot leg) matched it, AND three unrelated `claude` agent sessions matched it (their system prompt text quotes the pattern), AND the `grep` invocation used to audit the bug matched itself. A probe that can match the process asking the question is not a liveness probe. `codegen-drain`'s `watcher_probe_cmd/1` instead reads `codegen/gate-pending/queue.lock` — the single-flight lock `CodegenTestHarness.BuildLock` already writes before any drain OR solo build runs (see `context/loop.md`) — and reports `watcher=yes` iff the recorded `<label>` is exactly `"queue"` and the recorded pid is alive (`kill -0`). A `"solo"`-labeled lock, a dead pid, an absent lock, or a malformed lock all correctly resolve to `watcher=no`. The local and remote (`ssh`) legs of `cmd_status` share one predicate string (`watcher_probe_cmd/1`), so there is exactly one place this logic can drift. A `watcher=no` verdict prints its own remediation (`claude-build --queue --watch`), following the `make build-ready` precedent of a red verdict naming its own fix.

**`.incoming/` is a queue-invisible staging directory.** Every consumer of `codegen/pitches/ready/` globs that directory by name explicitly (`find "$READY_DIR" -maxdepth 1 -name "*.md"` in `claude-build.sh`); none glob all subdirectories of `codegen/pitches/`. A sibling `.incoming/` directory is therefore invisible to the build queue by construction, not by a filter added for this purpose.

## Pitfalls

- **`CODEGEN_DIR` must be absolute** — Relative paths break symlink resolution.
- **[shared] Worktree-cwd is ephemeral** — Launcher `--worktree` cwd destroyed at teardown. Export `CODEGEN_PITCH_ROOT` resolving durable main-repo root (via git-common-dir) BEFORE worktree re-root. Always-on exports ensure all paths inherit durable root.

---

## Trigger Keywords

deployment, server, prod, staging, dashboard box, Hetzner, CODEGEN_DIR, OCG_CODEGEN_DIR, hardcode, BASH_SOURCE, multi-location, install target vs source, codegen root, where does codegen run, three-repo ordering, context codegen platform, worktree cwd ephemeral, codegen-drain, drain-nodes.yaml, possession, fleet, multi-node, ssh lands as root, run_as, .incoming, quiescence gate, scp -p, watcher column, watcher probe, pgrep self-match, argv scanning, queue.lock, liveness probe, watcher=yes watcher=no

---

## Update When Changing

Update this file when:

- A new server or machine is added to the codegen install roster
- The dashboard box path changes
- A new install target directory is added
- The `OCG_CODEGEN_DIR` override semantics change
