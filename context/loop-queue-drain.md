# Multi-Pitch Queue Drain — `LoopQueueDrain`

`CodegenTestHarness.LoopQueueDrain` (`loop_queue_drain.ex`, 2,237 LOC). Drains `codegen/pitches/ready/`
in dependency order, spawning one fresh `codegen-build` child process per pitch — distinct from
`context/loop.md`'s single-cycle engine: this is the multi-pitch orchestrator ON TOP of it. Invoked via
`claude-build.sh --queue` / `pi-build.sh --queue`, which both exec `mix codegen.loop.queue`.

## Why This Is a Separate Domain From `loop.md`

Different process model (spawns a child `Port`, not an in-process call), different failure taxonomy
(ship/skip/halt vs the single-cycle's retry/rework), its own GC + circuit breaker + queue-wide spend
ceiling. Zero cross-pitch context accumulation — each child starts cold.

## Ordering

`LoopQueue.ordered_slugs/1` — topological sort over `blocks_on:` YAML frontmatter (legacy `Blocks-on:`
prose fallback when no frontmatter present, via `LoopQueue.parse_edges/2`). Raises on a dependency
cycle. A pitch whose dependency is unsatisfied (dep still in `draft/` or absent) is a SELECTION-time
gate — never selected, stays physically in `ready_dir`, skipped every scan, surfaced in a distinct
SKIPPED (unmet dep) bucket. This is NOT a failure; drain still returns `{:ok, shipped_count}`.

## Ship Verification — exit 0 is Necessary, Not Sufficient

A child's exit code 0 alone does NOT mean shipped. `handle_exit_zero/7` additionally requires:

1. `committed?` — HEAD moved forward (non-orphaning) since the pre-spawn `head_before` read.
2. A FRESH `gate_clear?` — verdict `"clear"` AND its recorded `base_sha` prefixes `head_before` AND the
   gate record's mtime is at/after this attempt's spawn timestamp (rejects a stale clear verdict left on
   disk by an EARLIER cycle attempt that failed without committing).

An exit-0 without a verified commit under a fresh clear gate (a "false-0") is treated as a deterministic
failure — same skip-and-continue path as a genuine nonzero exit.

**Committer-post-commit hiccup recovery** (ported from legacy `build-queue.sh`): a child exiting
non-zero AFTER HEAD already moved, with a fresh clear gate verdict, still counts as shipped rather than
halting the whole queue.

## Timeout vs Transient-Retry — Two Separate Paths

- **Watchdog timeout** (`:pitch_budget_secs`, default 7200s, env `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`)
  — ALWAYS stashes the dirty tree + retries once + skips on second timeout. NEVER routed through
  `transient?/1` classification (mirrors legacy `build-queue.sh`'s early `continue` on the timeout
  branch, before the transient-check block runs).
- **Transient retry** — `LoopQueue.transient?/1` classifies JSONL exit reasons; a transient failure
  retries with backoff, non-transient does not.

## Deterministic Failure — Skip, Never Silent Stash

A deterministic child failure (or a pitch exhausting its own transient retries) SKIPS-AND-CONTINUES:
the pitch stays physically in `ready_dir`, its dirty tree is committed to a NAMED
`queue-fail/<slug>/<ts>` branch (never an invisible `git stash` — `no-git-stash.sh` forbids that
everywhere in this repo). Recoverable via plain branch checkout. Never auto-restored — the stash-restore
seam only matches the `queue-timeout:` prefix, so a graded-and-rejected tree never silently re-enters a
retry.

**Terminal marker — read BEFORE `retry_eligible?/5`.** On a nonzero exit, `handle_nonzero_exit/8` first
calls `:terminal_marker_fn` (default `default_terminal_marker_fn/1`, reads
`codegen/gate-pending/terminal-state.json` — see the loop owner file's "Terminal Marker" section for the
producer). A present marker (`{:terminal, reason, owner}`) routes straight to this same
park+skip+breaker channel — printing `FAILED (deterministic: <owner> exhausted — <reason>) — parked, not
retried` — and is NEVER retried, even when `LoopQueue.transient?/1` would otherwise classify the exit as
retry-eligible. This is what makes a self-inflicted, deterministic exhaustion (a curator-doc or env-var
check the owning role genuinely could not fix) stop costing a full `codegen-build` price on every retry
instead of failing once. Absent or malformed marker (`:absent`) → falls through unchanged to
`retry_eligible?/5` — fail-open is correct here: absence means no deterministic claim was made, exactly
today's pre-marker behavior.

## Circuit Breaker

`:max_consecutive_fails` (default 3, env `CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS`). Any ship resets
the streak to 0. Hitting the threshold HALTs the drain with `{:error, reason}` — theory: a
systemically-broken environment (not an isolated bad pitch) is failing every build. Isolated failures
below the threshold are tolerated; `drain/1` returns `{:ok, shipped_count}` with a FAILED bucket naming
every skipped slug.

## Queue-Wide Spend Ceiling

`CODEGEN_BUILD_QUEUE_BUDGET_USD` — separate from the loop's per-cycle `--max-budget-usd`. Checked before
every pitch spawn (not between role invocations within a cycle). Absent by default, no ceiling.

## Logging GC

265 LOC of retention logic (7 constants) — best-effort per-class GC over the ephemeral `codegen/logging/`
directory between pitch spawns. Explicitly `# fail-loud-exempt` (best-effort; a GC failure never halts
the drain).

## Trigger Keywords

LoopQueueDrain, queue drain, codegen.loop.queue, --queue, build-queue.sh, ordered_slugs, blocks_on, transient?, watchdog timeout, pitch_budget_secs, CODEGEN_BUILD_QUEUE_BUDGET_USD, CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS, CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS, circuit breaker, queue-fail branch, handle_exit_zero, false-0, ship verification, terminal marker, terminal-state.json, terminal_marker_fn, blind retry, deterministic exhaustion
