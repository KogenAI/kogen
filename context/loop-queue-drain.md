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

## Exit 4 — Committed AND Retired, Dirty Tree (Ship-With-Warning)

A FOURTH distinct child outcome, alongside shipped / deterministic-failure / infra-abort:
`mix codegen.loop`'s `@dirty_tree_exit_code` (4). The child already ran `record_ship` and moved the
pitch out of `ready/`/`building/` into `shipped/` UNCONDITIONALLY before exiting — see `context/loop.md`
§ Possession by Rename. This is a SHIP, never a failure: `handle_exit_dirty_retired/8` accumulates
spend, publishes the commit (`publish_or_halt/4`), calls `ship/6` as a defensive fallback (idempotent —
a no-op if the child already shipped it; covers the rare shape where the child committed but crashed
between the mv and the exit, leaving the pitch stuck in `building/`), counts the pitch shipped, resets
`consecutive_fails` to 0, and NEVER adds the slug to `failed_slugs` or requeues it. Dispatched via a
dedicated `{:exit_code, @dirty_tree_exit_code}` arm placed BEFORE the generic `{:exit_code, _n}`
catch-all in `do_run_slug/4` — same precedence pattern as the existing `@infra_abort_exit_code` arm.

`ship/6` probes `building/` as a second source (alongside `ready/`) — REQUIRED, not cosmetic: every
SELECTED pitch is claimed into `building/` for the duration of its cycle (`context/loop.md`), so without
the probe, every claimed pitch's fallback ship raises `"in neither ready/, building/, nor shipped/"`.

## Timeout vs Transient-Retry vs Outage-Pause — Three Separate Paths

- **Watchdog timeout** (`:pitch_budget_secs`, default 7200s, env `CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS`)
  — ALWAYS stashes the dirty tree + retries once + skips on second timeout. NEVER routed through
  `transient?/1` classification (mirrors legacy `build-queue.sh`'s early `continue` on the timeout
  branch, before the transient-check block runs).
- **Outage pause** — `LoopQueue.transient?/1`-classified failures (excluding the post-commit-hiccup
  non-commit case) now route to `run_outage_pause/6` BEFORE `retry_eligible?/5` is ever consulted — see
  § Outage Pause below. A provider-classified transient failure no longer burns a `max_retries` slot or a
  `consecutive_fails` breaker strike.
- **Transient retry** (`retry_eligible?/5`) — still reachable for the post-commit-hiccup non-commit case
  (`gate_clear? and not committed?`), which is not a provider-outage signal.

## Outage Pause

A `transient_fn.(jsonl)`-true failure (not the non-commit gate-clear case) enters an outage pause instead
of a retry-ladder attempt: `:probe_fn` (default `default_probe_fn/1`, a HARD-BOUNDED ~20s
`claude --print -- "ok"` liveness ping via the same `Port.open` + receive-timeout + `Port.close` idiom as
`default_spawn_fn/5` — NEVER unbounded, an unbounded ping against an unreachable provider hangs
indefinitely) is polled with capped-backoff-with-jitter sleeps (`pick_delay/2`, same ladder as the retry
delays) between probes. `:up` resumes the SAME slug via `run_slug/4`; `:down` sleeps and re-probes. Neither
outcome touches `:consecutive_fails` or `:retry_count`. Exceeding `:outage_pause_secs` (default 900s, env
`CODEGEN_BUILD_QUEUE_OUTAGE_PAUSE_SECS`) HALTs the drain with a message naming "provider outage" —
DISTINCT from the "consecutive deterministic failures" breaker message (§ Circuit Breaker) — leaving the
pitch untouched in `ready_dir` for a re-run once the provider recovers.

## Deterministic Failure — Skip, Never Silent Stash

A deterministic child failure SKIPS-AND-CONTINUES: the pitch stays physically in `ready_dir`, its dirty
tree is committed to a NAMED `queue-fail/<slug>/<ts>` branch (never an invisible `git stash` —
`no-git-stash.sh` forbids that everywhere in this repo). Recoverable via plain branch checkout. Never
auto-restored — the stash-restore seam only matches the `queue-timeout:` prefix, so a graded-and-rejected
tree never silently re-enters a retry.

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

The increment lives at TWO identical sites in `handle_nonzero_exit/8` (the terminal-marker deterministic
arm and the general catch-all deterministic arm) — an outage pause (§ Outage Pause) is a cond clause
placed BEFORE both, so neither site is ever reached on a provider-classified transient failure; the
breaker counts deterministic failures only.

## Auto-Demotion After Repeated Deterministic Failure

A pitch that fails DETERMINISTICALLY twice — never a transient/outage/timeout, which never reach this
path — is demoted from `ready/` back to `draft/`, so a guaranteed-failing pitch stops re-burning money on
every drain restart. `record_build_failure/2` is called from the SAME three arms that call
`park_failed_tree/2` (the false-exit-0 catch-all in `handle_exit_zero/8`, the terminal-marker arm in
`handle_nonzero_exit/8`, and its general `true ->` catch-all) — never from the outage-pause or
retry-eligible arms above them in the same `cond`.

**Durable counter, not `:failed_slugs`.** The count is a `build_failures:` YAML frontmatter field written
directly onto the pitch file — durable across a `--watch` restart (the file persists on disk), unlike
`:failed_slugs` (an in-memory `MapSet` that resets to empty on every fresh `drain/1` call). This is the
gap a deterministically-failing pitch exploited: a watcher restart rebuilt it fresh, at full price, every
time.

**Threshold = 2, env `CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS`.** On the failure that brings the counter to
`:max_pitch_fails` (default 2), `LoopQueue.write_demotion!/5` moves the pitch to `draft/<slug>.md` with
`status: SHAPING`, `demoted_from: ready`, `demote_reason: deterministic-build-failure-x<N>`, and an
appended `## Build failure history` table row — byte-for-byte the hand-written template a human authored
for `the-guard-parses-quotes-worse-than-the-shell-it-guards` before this feature existed. Below the
threshold, only the counter increments (`LoopQueue.write_build_failures!/2`); the pitch stays in `ready/`.

**Path resolution mirrors `write_frontmatter!/4`.** `resolve_pitch_path/2` probes `ready_dir` first (the
normal shape — a failed cycle already restored its claim via `restore_claim/2`), then `building_dir` (a
crashed child that never restored its claim, stranding the slug there — see § Ship Verification). A
demotion never targets `shipped_dir` — a pitch that reached `shipped/` was never a failure.

**Cascade is named, not silent.** `LoopQueue.dependents_of/2` scans `ready_dir` for every pitch whose
`blocks_on:` edges name the just-demoted slug, and the demotion stderr line lists them
(`queue: DEMOTED <slug> after 2 deterministic failures -> draft/<slug>.md (blocked: <dependents>)`) — the
existing `blocked_by_unmet_dep`/SKIPPED-bucket machinery already strands them as unmet-dep skips with no
code change; this only names the cascade so the operator sees it.

**Fail-open on I/O error.** `record_build_failure/2` rescues any read/write/rename failure (e.g. the pitch
file already moved out of both `ready_dir` and `building_dir` by a stubbed/pathological spawn) — a demote
failure prints a loud stderr line and leaves the pitch wherever it already is; it never aborts the drain.
This mirrors `park_failed_tree/2`'s and `draft_failure/4`'s existing fail-open posture for the same class
of observation/bookkeeping side effect.

**Layered on top of, not instead of, the circuit breaker.** A demotion changes neither `:failed_slugs` nor
`:consecutive_fails` — the breaker (§ Circuit Breaker) remains a pure box-health backstop; a systemically
broken environment still HALTs the whole drain even when every individual pitch is auto-demoting cleanly.

## Publish — a Watched Node Publishes Its Own Commits

The drain publishes every commit it lands (`publish_or_halt/4`, called at ALL THREE commit-landed ship
sites — `handle_exit_zero`'s `committed? and gate_clear?` arm, and BOTH `handle_nonzero_exit` ship arms:
child-already-shipped and drain-fallback), never relying on a human-started supervisor session (e.g.
`claude-babysit`) to push on its behalf.

**Preflight, once, before any spawn** (`:publish_preflight_fn`, default `default_publish_preflight_fn/1`):
resolves the current branch's upstream (`@{u}`) and proves transport with `git ls-remote --exit-code
<remote> refs/heads/<branch>`. No upstream, detached HEAD, or unreachable remote → `drain/1` refuses
before any spawn, `{:error, reason}`, $0 spent.

**Per landed commit** (`:git_publish_fn`, default `default_git_publish_fn/2`), called BEFORE the pitch
file moves `ready/ → shipped/` so the sha the ship record stamps is always the sha that reached origin:

1. `fetch` the upstream. Remote already an ancestor of HEAD → plain `push` → `{:ok, :unchanged}` (the
   single-node steady state).
2. Remote moved → `rebase <upstream>` → `push` → `{:ok, {:rewritten, new_head}}`. The rebase invalidates
   the ship record `LoopQueue.record_ship/4` was about to stamp with the PRE-rebase sha, so
   `publish_or_halt/4` re-stamps it with `new_head` before shipping (`LoopQueue.write_frontmatter!/4`
   resolves `ready/` then falls back to `shipped/` — needed because some ship sites re-stamp a pitch
   already moved).
3. Conflict → `rebase --abort` → `{:error, reason}`. NEVER `--force`, on any path.

**Halt, don't continue, on a publish failure.** `park_published_commit/3` parks the already-landed commit
to a NAMED `recovery/<slug>/<ts>` branch via `git branch -f` (clean-tree-safe — unlike `park_failed_tree/2`,
which parks a DIRTY tree via stash and is a no-op on a clean tree; a successful-but-unpublishable commit
always leaves a clean tree). The pitch stays in `ready_dir`, and the drain returns `{:error, reason}`
rather than spawning the next pitch — continuing would build on an unpublished base, and the next push
would fail too, compounding the divergence silently. Halting bounds the loss at `ahead=1`.

`claude-babysit`/`pi-babysit` no longer push — `harnesses/shared/prompt-bodies/babysit.txt` step 5 is now
a verify-only step (probe HEAD not ahead of upstream), since the drain publishes on its own.

## Queue-Wide Spend Ceiling

`CODEGEN_BUILD_QUEUE_BUDGET_USD` — separate from the loop's per-cycle `--max-budget-usd`. Checked before
every pitch spawn (not between role invocations within a cycle). Absent by default, no ceiling.

## Logging GC

265 LOC of retention logic (7 constants) — best-effort per-class GC over the ephemeral `codegen/logging/`
directory between pitch spawns. Explicitly `# fail-loud-exempt` (best-effort; a GC failure never halts
the drain).

## Failure Drafting — `:draft_fn` Seam

On the two TERMINAL FAILED arms only (exit-0-without-verified-commit, and nonzero-with-retries-exhausted
— never a HALT arm: infra abort or orphaned base), the drain calls `:draft_fn` right after
`park_failed_tree/2` (tree already parked/clean — sequencing moots any stash-sweep question). The gate
verdict passed to `draft_fn` is the SAME `gate_verdict_fn.(cwd)` value each arm already read for its own
`gate_clear?` check — `draft_failure/4` never re-reads it, so drafting adds zero extra `:gate_verdict_fn`
calls (load-bearing for tests that count that seam's call sequence, e.g. the consecutive-fail-streak
tests). Default
`default_draft_fn/4` shells a headless `codegen-call --harness=claude_code --model=opus --effort=high
--system-prompt @harnesses/claude/document-system-prompt.md --json-schema
@harnesses/claude/document.schema.json`, mirroring `codegen-propose`'s precedent. Input: the failing
slug, the gate verdict, the failing cycle's last result text, and the FULL BODY of every existing
`status: SKELETON` draft under `<cwd>/codegen/pitches/draft/` (`skeleton_drafts/1` — SHAPING/SHAPED
drafts are never read or merge targets). Response `{action: "new"|"merge", slug, target_slug, body}`:
`new` writes `<slug>.md`; `merge` overwrites `target_slug` ONLY when that slug was among the supplied
skeletons (`apply_draft_decision/3` — never a blind overwrite of an unlisted/in-flight draft). Fail-open:
a `codegen-call` error is loud stderr, `state.drafted_count` unchanged, drain continues — mirrors
`park_failed_tree/2`'s own fail-open contract; the draft is an observation, not a required value.
`spend_report/3` reports `state.drafted_count` in its end-of-run line.

## Trigger Keywords

LoopQueueDrain, queue drain, codegen.loop.queue, --queue, build-queue.sh, ordered_slugs, blocks_on, transient?, watchdog timeout, pitch_budget_secs, CODEGEN_BUILD_QUEUE_BUDGET_USD, CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS, CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS, circuit breaker, queue-fail branch, handle_exit_zero, false-0, ship verification, terminal marker, terminal-state.json, terminal_marker_fn, blind retry, deterministic exhaustion, draft_fn, skeleton draft, document-system-prompt, drafted_count, publish, git_publish_fn, publish_preflight_fn, publish_or_halt, recovery branch, park_published_commit, unpublished commit, git push, git rebase, babysit push, watched node, exit 4, dirty_tree_exit_code, handle_exit_dirty_retired, building/, claim_pitch, possession, ship-with-warning, auto-demotion, build_failures, demoted_from, demote_reason, status SHAPING, Build failure history, record_build_failure, write_demotion, write_build_failures, resolve_pitch_path, dependents_of, CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS, max_pitch_fails, demote pitch back to draft
