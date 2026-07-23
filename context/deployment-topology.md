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

**A `handoff_receipt:` travels WITH the transferred pitch, unchanged.** A concrete cross-pitch `handoffs:` deferral (see `context/pitch-lifecycle.md` § Frontmatter Schema) is reconciled and stamped BEFORE promotion to `ready/` — but `assign` moves exactly ONE pitch file, so the counterpart participant a `handoffs:` record names may be entirely absent on the destination node. The receipt is what makes this safe: it is bytes computed at stamp time, self-contained in the transferred file, and `Mix.Tasks.Codegen.Loop.claim_pitch!/2` re-verifies it against the pitch's OWN `handoffs:` records before claiming — no live counterpart, no second reconciliation, no ssh round-trip back to the source node is ever required.

Inventory lives at `codegen/drain-nodes.yaml` (gitignored — machine-local topology, same posture as `<app>/codegen/manifest.yaml`). Each node entry: `name`, `repo` (absolute path on that node), optional `host` (ssh target; omit for the local node), optional `run_as` (see below), optional `launch` (descriptive only — `codegen-drain` never starts a watcher on any node).

**Fleet inventory is not product support policy.** `drain-nodes.yaml` names which boxes CAN run a build; it is never a source for a project's REQUIRED platform set. That contract lives in `PROJECT_CONTEXT.md` § Required Platforms (`required_platforms: [...]`), declared independently — see `context/shaper-discipline.md` § Completeness Contract for Required-Platform Coverage Pitches.

**ssh-lands-as-root discipline.** Some fleet hosts land an interactive `ssh` session as `root` even though the actual repo is owned by a dedicated service user (e.g. `studio`). A plain `scp`/`ssh` write in that situation creates a **root-owned file inside a non-root-owned repo** — it looks harmless (the pitch still builds; `mv` only needs directory permission) until `LoopQueue.record_ship/4` tries to write the ship record **into the pitch file itself** and hits `EACCES`, raising and refusing the ship. The pitch is then stuck in `ready/` with its work already landed — a corpse manufactured by a `chown` bit, not a code bug.

`codegen-drain` avoids this by staging every remote transfer through `/tmp` (root-writable, harmless), then using `install -o <run_as> -g <run_as>` to land the file inside `codegen/pitches/.incoming/` with the CORRECT ownership before it ever enters the tracked repo tree, then `su - <run_as> -c 'mv ...'` for the final same-filesystem move into `ready/`. Nodes with no `run_as` in the inventory (the ssh user already owns the repo) skip the `install -o` step — there is no ownership boundary to cross.

Every shared `remote_run` probe invokes `ssh -n`, in both the plain and `run_as` branches. Fleet callers enumerate inventory rows on stdin; allowing a remote command to inherit that descriptor lets a middle node consume the next row, silently hiding the final node from `status` or `assign --auto`. Detaching SSH stdin preserves complete inventory traversal while leaving the fail-closed dependency snapshot contract unchanged.

**Why the transfer never uses `scp -p`.** The `--watch` engine's quiescence gate (`quiescence_exclude/1` in `loop_queue_drain.ex`) treats a file as "still arriving" when `mtime > cutoff` — i.e. a recent mtime is what excludes a file from being selected mid-transfer. `scp -p` preserves the SOURCE mtime on the destination, which would make a freshly-arrived file read as "already old" and thus immediately eligible for build selection while bytes might still be incomplete on a slower path. `codegen-drain` never passes `-p` to `scp`; the final landing step is always a same-filesystem `mv`, which (per the engine's own moduledoc) is "already-quiescent the instant it lands" regardless of the mtime it carries.

**`codegen-drain status` also reports a `building=` column** — the count of `.md` files under
`codegen/pitches/building/` on that node (a claimed, in-flight pitch — see `context/loop.md` §
Possession by Rename and `context/pitch-lifecycle.md`). Local nodes `find` the directory directly;
remote nodes append the count as the LAST line of the same composed ssh probe `status` already sends
(`sed -n '4p'`, appended after the pre-existing count/incoming/watcher lines at `1p`/`2p`/`3p` so their
offsets are unchanged). `--json` output carries the same value as `building_count`. `cmd_assign` is
untouched — fleet moves stay `ready/`-only; a claimed pitch is mid-cycle, not something to hand between
nodes.

**`codegen-drain status`'s `watcher=` column reads the lock file, never argv.** Earlier versions resolved `watcher=yes/no` via `pgrep -f "mix codegen.loop.*--cwd=$repo"` — an argv-scanning liveness probe that matches ANY process whose commandline happens to quote the search pattern, not only a real watcher. Verified live: a solo `mix codegen.loop --cwd=<repo>` build (`dispatch.sh`'s one-shot leg) matched it, AND three unrelated `claude` agent sessions matched it (their system prompt text quotes the pattern), AND the `grep` invocation used to audit the bug matched itself. A probe that can match the process asking the question is not a liveness probe. `codegen-drain`'s `watcher_probe_cmd/1` instead reads `codegen/gate-pending/queue.lock` — the single-flight lock `CodegenTestHarness.BuildLock` already writes before any drain OR solo build runs (see `context/loop.md`) — and reports `watcher=yes` iff the recorded `<label>` is exactly `"queue"` and the recorded pid is alive (`kill -0`). A `"solo"`-labeled lock, a dead pid, an absent lock, or a malformed lock all correctly resolve to `watcher=no`. The local and remote (`ssh`) legs of `cmd_status` share one predicate string (`watcher_probe_cmd/1`), so there is exactly one place this logic can drift. A `watcher=no` verdict prints its own remediation (`claude-build --queue --watch`), following the `make build-ready` precedent of a red verdict naming its own fix. **`watcher=` is retained unchanged** — it is the raw signal `health=` (below) computes from, not replaced by it.

**A `handoff_receipt:` travels WITH the transferred pitch, unchanged.** A concrete cross-pitch `handoffs:` deferral (see `context/pitch-lifecycle.md` § Frontmatter Schema) is reconciled and stamped BEFORE promotion to `ready/` — but `assign` moves exactly ONE pitch file, so the counterpart participant a `handoffs:` record names may be entirely absent on the destination node. The receipt is what makes this safe: it is bytes computed at stamp time, self-contained in the transferred file, and `Mix.Tasks.Codegen.Loop.claim_pitch!/2` re-verifies it against the pitch's OWN `handoffs:` records before claiming — no live counterpart, no second reconciliation, no ssh round-trip back to the source node is ever required. See § Fleet Inventory for the full handoff reconciliation model.

**`codegen-drain status` also reports a computed `health=` verdict, plus git state and in-flight process detail — so a supervisor never re-derives box state from an ad-hoc `ps` grep.** `box_probe_cmd/1` emits one composed shell snippet (same textual-sharing discipline as `watcher_probe_cmd/1` — one predicate, run by both the local `bash -c` leg and the remote `ssh` leg of `cmd_status`, so the two legs can never drift): git `head`/`behind`/`ahead`/`dirty` for the node's repo (`behind`/`ahead` are `null` with no upstream, never a silently-wrong `0`), the newest `codegen/logging/*_cycle.jsonl` file's mtime + slug, and every live `claude`/`beam.smp` process's `pid`/`ppid`/elapsed-seconds — filtered with `awk`, NEVER a `ps | grep` pipe (that pattern is exactly the self-match class test case (t) in `codegen-drain_test.sh` closes; a comment merely describing the avoided pattern must also dodge the regex, or the guard fires on its own prose). `classify_health/3` (pure, no I/O) then derives:

- `unreachable` — ssh failed (same as `reachable:false` today).
- `unknown` — the box probe itself failed (e.g. `ps` unusable on that node) — the probe emits an explicit `PROBE_OK`/`PROBE_FAIL` sentinel line precisely so this case is never confused with a healthy idle box; a `--json` `reason` field carries why.
- `wedged` — any in-flight role process is orphaned (`ppid == 1`, reparented to init — its drain parent died), OR has run longer than `CODEGEN_DRAIN_ROLE_MAX_ETIME_SECS` (default 3600s), OR the newest cycle log has not advanced within `CODEGEN_DRAIN_LOG_STALE_SECS` (default 900s) — both env-overridable, genuinely-optional tuning knobs, not masking defaults.
- `working` — the queue watcher is live, or at least one role process is in flight, and none of the wedge conditions fired.
- `idle` — no watcher, no role process.

`--json` output is purely additive: the six pre-existing keys (`node`, `reachable`, `ready_count`, `incoming_count`, `watcher`, `building_count`) are unchanged in name, type, and position; `health`, `reason`, `head`, `behind`, `ahead`, `dirty`, and a `builds` array (`{pid, ppid, etime_secs, orphaned, slug, slug_confidence}` per in-flight process) are appended. `slug_confidence` is `"low"` whenever more than one role process is live in the same checkout (mtime-based slug correlation cannot disambiguate two concurrent builds) — the pids/ppid/elapsed/orphan fields stay correct regardless of slug ambiguity. Text output prints one indented `build pid=… ppid=… elapsed=…s slug=… [ORPHANED]` line per in-flight process beneath the summary row.

**`.incoming/` is a queue-invisible staging directory.** Every consumer of `codegen/pitches/ready/` globs that directory by name explicitly (`find "$READY_DIR" -maxdepth 1 -name "*.md"` in `claude-build.sh`); none glob all subdirectories of `codegen/pitches/`. A sibling `.incoming/` directory is therefore invisible to the build queue by construction, not by a filter added for this purpose.

**`codegen-drain assign --auto` wires the lane partitioner to the mover — no human chooses slug→node.** `mix codegen.pitches.scope --lanes=N --json` (a machine-readable leg alongside the pre-existing ANSI-prose report; requires `--lanes`, mirrors the `codegen-drain status --json` shape convention) emits `{"lanes":[[slug,...],...],"global_hot":[slug,...],"unrouted":[slug,...]}` — the same partition `LoopQueue.partition/2` already computes (scope collisions balanced into lanes, `blocks_on` folded into the same union-find graph so a dependency pair never splits across lanes). `assign --auto` reads THIS box's fleet inventory, counts reachable nodes (`reachable_nodes`, same find-ready ssh probe `status` uses) as `N`, shells `mix codegen.pitches.scope --dir=ready --cwd=<this-box> --lanes=N --json --fleet-safe [--externally-referenced=<comma-list>]` from `<cwd>/test_harness`, then places lane _i_ → reachable-node _i_ (inventory order) by calling the SAME single-slug transfer `assign --slug --node` already uses (extracted as `cmd_assign_one` — no new mover, no new checksum path, no new resurrection guard). `GLOBAL-HOT` and `UNROUTED` slugs are printed by name and never placed — `--auto` inherits the partitioner's own contract unchanged. Zero reachable nodes → refuse (exit 1, named); a mid-placement transfer failure stops immediately (fail-closed) — already-placed lanes stay placed, remaining lanes are not attempted. Test seam: `CODEGEN_DRAIN_SCOPE_CMD` overrides the mix shell-out with a stub emitting canned JSON, so hook tests prove the JSON→lane→node wiring hermetically without a real mix/BEAM run (the mix task's own `--json` output shape is proven by its ExUnit suite).

**Fleet distribution never separates a ready pitch from a prerequisite or dependent — dependency chains stay on one node.** Before any real (non-no-op) cross-node transfer, `codegen-drain` builds a `fleet_snapshot`: it probes EVERY node declared in `codegen/drain-nodes.yaml`, including the source node, via `fleet_probe_cmd` — a self-contained snippet using only `find`/`base64`/shell builtins (no `yq` dependency on the PROBED node; a remote box may lack mikefarah/yq entirely). Each node emits `STATE <ready|building|shipped> <slug>` for every pitch it holds, plus the full bytes of every READY pitch as one base64 line. The INITIATING node alone decodes (`yq -r '@base64d'`) and parses (`yq --front-matter=extract -r '.blocks_on[]'`) — one strict parser, no duplicate remote logic. FAIL-CLOSED: any unreachable node, missing `PROBE_DONE` sentinel (the marker that distinguishes "reachable but nothing there" from "never answered"), malformed `STATE` line, or unparseable frontmatter aborts the ENTIRE assignment (exit 1, named) before any transfer — an incomplete fleet view can never prove co-location. `inventory_nodes` is the single enumerator shared by `fleet_snapshot`, `reachable_nodes`, and `status` — it validates non-empty unique names and exact line-count parity, closing a prior bug where the iterator silently dropped the final declared node.

**`LoopQueue.fleet_partition/3`** is the fleet-safe sibling of `partition/2`, exposed via `mix codegen.pitches.scope --fleet-safe` (requires `--lanes` and `--json`; adds a fourth JSON key `dependency_bound`; plain `--json` output stays byte-identical). A component is DEPENDENCY-BOUND — held out of every lane — when it has an outgoing `blocks_on:` edge (INCLUDING a dead edge to a dependency outside this batch, the crux inversion of `partition/2`'s own dead-edge-ignore behavior: here a dead edge signals the dependency may already be shipped on a DIFFERENT node), is named in `--externally-referenced` (slugs some other fleet node's ready pitch depends on), or shares a `scope:` collision with either. `assign --auto` computes `--externally-referenced` from its own `fleet_snapshot`'s edges before shelling the scope task, and prints `DEPENDENCY-BOUND (kept on source node — build chain locally): <slugs>` — exactly like its existing `GLOBAL-HOT`/`UNROUTED` treatment, these slugs are never placed by `--auto`; they stay on the source node so the whole chain builds there.

**Targeted `assign --slug --node` runs a bidirectional `dependency_preflight` before any real transfer** (skipped for the same-node no-op, which returns before it runs). OUTGOING: every `blocks_on:` dependency the slug itself declares must already exist on the target (ready, building, or shipped state — mirrors the local queue's own `ready ∪ shipped` satisfaction contract; `building` means the dependent will wait locally there, which composes). INCOMING: every fleet-ready pitch, on ANY node, naming the slug as ITS dependency must ALREADY reside on the target too — moving the slug away would otherwise strand that dependent. Either violation refuses (exit 1) naming the blocking edge, its current owner, and a concrete remediation command (move the dependent to the prerequisite's node, never the reverse — no automatic multi-pitch transfer, no copying ship records across nodes).

**Assigning a pitch to the node it already occupies is a no-op, never a refusal.** `cmd_assign_one`'s local-node branch compares `local_path` (source) against `dest` (destination) with `[[ "$local_path" -ef "$dest" ]]` — true whenever the two paths are the SAME on-disk file (inode+device match, including through a symlinked `--cwd`), false for a genuinely distinct file. When true, it prints `already at <node> (no-op)` and returns 0 BEFORE the resurrection guard runs — this matters because `--auto`'s partition routinely places a lane onto the same box the command is executing from (the common single-owner case for a live fleet), and without this check the guard's `[[ -f "$dest" ]]` fired unconditionally true (dest IS the source), aborting the entire `--auto` run on its first same-node lane. The resurrection guard still fires, unchanged, for a genuine cross-node duplicate — a distinct file at the target holding the same slug.

## Pitfalls

- **`CODEGEN_DIR` must be absolute** — Relative paths break symlink resolution.
- **[shared] Worktree-cwd is ephemeral** — Launcher `--worktree` cwd destroyed at teardown. Export `CODEGEN_PITCH_ROOT` resolving durable main-repo root (via git-common-dir) BEFORE worktree re-root. Always-on exports ensure all paths inherit durable root.

---

## Trigger Keywords

deployment, server, prod, staging, dashboard box, Hetzner, CODEGEN_DIR, OCG_CODEGEN_DIR, hardcode, BASH_SOURCE, multi-location, install target vs source, codegen root, where does codegen run, three-repo ordering, context codegen platform, worktree cwd ephemeral, codegen-drain, drain-nodes.yaml, possession, fleet, multi-node, ssh lands as root, ssh -n, stdin ownership, run_as, .incoming, quiescence gate, scp -p, watcher column, watcher probe, pgrep self-match, argv scanning, queue.lock, liveness probe, watcher=yes watcher=no, assign --auto, lane to node, auto-partition, --json partition, codegen.pitches.scope --json, reachable_nodes, CODEGEN_DRAIN_SCOPE_CMD, building column, building_count, claimed pitch, in-flight count, health verdict, box health, box_probe_cmd, classify_health, wedged, orphaned process, ppid 1, probe_fail, probe_ok, slug_confidence, git head behind ahead dirty, fleet supervisor, codegen_drain_log_stale_secs, codegen_drain_role_max_etime_secs, fleet_snapshot, fleet_probe_cmd, PROBE_DONE, inventory_nodes, dependency_preflight, DEPENDENCY-BOUND, dependency_bound, fleet_partition, --fleet-safe, --externally-referenced, dependency chains stay local, strand dependent, targeted assign refuses, complete fleet topology, fail-closed fleet snapshot, handoff_receipt fleet transfer, bilateral handoff record

---

## Update When Changing

Update this file when:

- A new server or machine is added to the codegen install roster
- The dashboard box path changes
- A new install target directory is added
- The `OCG_CODEGEN_DIR` override semantics change
