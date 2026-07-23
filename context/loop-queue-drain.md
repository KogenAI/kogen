# Multi-Pitch Queue Drain — `LoopQueueDrain`

`CodegenTestHarness.LoopQueueDrain` (`loop_queue_drain.ex`). Drains `codegen/pitches/ready/`
in dependency order, spawning one fresh `codegen-build` child process per pitch — distinct from
`context/loop.md`'s single-cycle engine: this is the multi-pitch orchestrator ON TOP of it. Invoked via
`claude-build.sh --queue` / `pi-build.sh --queue`, which both run `mix codegen.loop.queue` through the
shared `harnesses/shared/loop-signal-bridge.sh` helper (`run_supervised_loop`) rather than a direct
`exec` — job-controlled, non-exec, so a terminal Ctrl-C becomes a group SIGTERM the BEAM's
`BuildSignalHandler` can catch instead of hitting Erlang's uncatchable SIGINT handler directly. Same
helper also supervises both `dispatch.sh` twins — see `context/harnesses.md` § Orchestrated Build Mode.

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
retry-eligible. This is what makes a self-inflicted, deterministic exhaustion (a curator-doc, env-var, or
turn-0 orientation-doc-repair check the owning role genuinely could not fix) stop costing a full
`codegen-build` price on every retry instead of failing once. A turn-0 orientation-repair exhaustion
(`turn0_repair_exhausted/3`, owner `"context-curator"`) writes this SAME marker, alongside the
gate/curator-doc/env-var producers — no separate consumer path. Absent or malformed marker (`:absent`) →
falls through unchanged to `retry_eligible?/5` — fail-open is correct here: absence means no deterministic
claim was made, exactly today's pre-marker behavior. The marker WRITE ITSELF is now REQUIRED, not
best-effort — a failed write raises `InfraAbort` at the producer rather than silently leaving a
deterministic exhaustion unmarked (see the loop owner file's "Terminal Marker" section).

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
every drain restart. `record_build_failure/4` is called from the SAME three arms that call
`park_failed_tree/2` (the false-exit-0 catch-all in `handle_exit_zero/8`, the terminal-marker arm in
`handle_nonzero_exit/8`, and its general `true ->` catch-all) — never from the outage-pause or
retry-eligible arms above them in the same `cond`.

**Every counted deterministic failure writes a durable evidence row — not only the demoting one.**
`record_build_failure/4` resolves the pitch path, computes the count, builds a
`build_failure_evidence/5` map from values the calling arm already has bound (classified cause,
owner/phase attribution, a gate witness ONLY when fresh, cost, recovery branch, and the repo-relative
`_build.log` path), formats it into one `## Build failure history` table row via
`format_failure_row/1`, and persists it — on failure #1 via `LoopQueue.write_build_failures!/3`, on the
THRESHOLD failure via `LoopQueue.write_demotion!/5`. `CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS` controls only
WHEN the pitch moves to `draft/`; it does not gate whether a row is written.

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
threshold, the counter increments AND the same durable evidence row is appended
(`LoopQueue.write_build_failures!/3`); the pitch stays in `ready/`.

**Path resolution mirrors `write_frontmatter!/4`.** `resolve_pitch_path/2` probes `ready_dir` first (the
normal shape — a failed cycle already restored its claim via `restore_claim/2`), then `building_dir` (a
crashed child that never restored its claim, stranding the slug there — see § Ship Verification). A
demotion never targets `shipped_dir` — a pitch that reached `shipped/` was never a failure.

**Cascade is named, not silent.** `LoopQueue.dependents_of/2` scans `ready_dir` for every pitch whose
`blocks_on:` edges name the just-demoted slug, and the demotion stderr line lists them
(`queue: DEMOTED <slug> after 2 deterministic failures -> draft/<slug>.md (blocked: <dependents>)`) — the
existing `blocked_by_unmet_dep`/SKIPPED-bucket machinery already strands them as unmet-dep skips with no
code change; this only names the cascade so the operator sees it.

**Fail-CLOSED on a genuine I/O error; a distinct WARN-and-continue for an absent pitch file.**
`record_build_failure/4` rescues any read/write/rename failure against a pitch file that IS present and
returns `{:error, "queue: HALTED — could not persist failure evidence for <slug>: <reason>"}` — every
call site halts the drain on this result BEFORE breaker accounting or another spawn. Required evidence
must never silently vanish. The ONE exception is a pitch file genuinely ABSENT from both `ready_dir` and
`building_dir` (an out-of-band actor, typically the child's own committer, already moved it to
`shipped/` before this classification ran) — there is no pitch left to record evidence INTO, so this
warns loud and continues rather than halting. Contrast `draft_failure/4` (the advisory skeleton
drafter), which stays fail-open: it creates optional follow-up work, not the required durable record.

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
`park_failed_tree/2` (tree already parked/clean — sequencing moots any stash-sweep question). The 4th
`:draft_fn` arg is a COMPOSED failure block, never a bare gate verdict — see § Failure Classification
below. Building it never re-reads `:gate_verdict_fn`; both arms already read it for their own
`gate_clear?` check, and `classify_drain_failure/1` + `format_failure_block/3` consume that same
already-computed value (load-bearing for tests that count that seam's call sequence, e.g. the
consecutive-fail-streak tests). Default
`default_draft_fn/4` shells a headless `codegen-call --harness=claude_code --model=opus --effort=high
--system-prompt @harnesses/claude/document-system-prompt.md --json-schema
@harnesses/claude/document.schema.json`, mirroring `codegen-propose`'s precedent. Input: the failing
slug, the composed failure block, the failing cycle's last result text, and the FULL BODY of every
existing `status: SKELETON` draft under `<cwd>/codegen/pitches/draft/` (`skeleton_drafts/1` —
SHAPING/SHAPED drafts are never read or merge targets). Response `{action: "new"|"merge", slug,
target_slug, body}`: `new` writes `<slug>.md`; `merge` overwrites `target_slug` ONLY when that slug was
among the supplied skeletons (`apply_draft_decision/3` — never a blind overwrite of an unlisted/in-flight
draft). Fail-open: a `codegen-call` error is loud stderr, `state.drafted_count` unchanged, drain
continues — mirrors `park_failed_tree/2`'s own fail-open contract; the draft is an observation, not a
required value. `spend_report/3` reports `state.drafted_count` in its end-of-run line.

**Failure Classification — `classify_drain_failure/1` + `format_failure_block/3`**: a retry-exhausted or
false-exit-0 skeleton must never present as a bare, unqualified `Gate verdict: clear` — that reads to any
operator as "nothing was wrong here" and buries the real cause (observed instance:
`the-guard-parses-quotes-worse-than-the-shell-it-guards`, drain-drafted as FAILED on a cycle that was
actually clear and committed). Both terminal-FAILED arms build a small map of already-computed booleans
(`transient?`, `gate_clear?`, `committed?`, `gate_verdict`, `retry_count`) and classify PURELY from
those — zero new seam reads. Clause order is significant, transient-first:

1. `transient?: true` → `:transient_exhausted` — "retried N× — child produced no result record
   (killed/crashed mid-flight)". Checked FIRST: a child with no result record has no trustworthy ship
   signal at all; attributing that to ship-detection instead would misdirect the operator.
2. `gate_clear?: true, committed?: false` → `:ship_not_verified` — "gate fresh-clear but HEAD did not
   advance to a descendant of head_before (ship not verified — another supervisor may have shipped it
   first)". This is a distinct concept from (1): a REAL result record exists and the gate genuinely
   passed THIS cycle, but the ship itself was never verified (e.g. a concurrent drain shipped the same
   slug first — see `a-landed-pitch-cannot-be-handed-out-again`).
3. Catch-all → `:gate_failed` — "gate verdict=<v>" (never a silent `nil`/defensive sink; every
   terminal-FAILED cycle gets a named cause).

`format_failure_block/3` composes `Failure cause: <atom> — <str>\nGate verdict: <display>\n`. `display`
qualifies a raw `"clear"` verdict THREE ways: `"clear (STALE — not fresh for this cycle)"` when
`gate_fresh?/3` rejected it (a genuinely stale record from an EARLIER cycle), `"clear (ship not
verified — HEAD did not advance)"` when the verdict IS fresh for this cycle but the cause is
`:ship_not_verified`, or `"clear (transient — child produced no result record this cycle)"` when the
cause is `:transient_exhausted` — `transient?` is checked FIRST in `classify_drain_failure/1`, so a
fresh-clear gate left over from a prior successful run in the same working tree can still co-occur with
a crashed/killed child on THIS cycle. All three qualifiers apply regardless of which cause fired — a
drafted block's raw-`"clear"` verdict is NEVER rendered unqualified for ANY cause atom.
`draft_failure/4` also emits a loud `queue: WARN — <slug> classified <atom> but raw gate verdict on disk
reads "clear" (<matching qualifier text>)` stderr line when the cause is
`:ship_not_verified`/`:transient_exhausted` while the raw on-disk verdict still reads `clear` — the
qualifier in the WARN matches the cause atom (never a hardcoded "stale" for a fresh-but-unverified or
fresh-but-transient cause) — the buried-contradiction case surfaced immediately, not only discoverable
by reading the drafted skeleton later. The `:draft_fn` seam signature is UNCHANGED
(`(cwd, slug, jsonl, failure_block -> {:ok, path} | {:error, reason})`, still 4-arity) — only the STRING
content of the 4th arg changed from a bare verdict to the composed block; `build_draft_prompt/4` renders
whichever shape it receives (a composed block starting with `"Failure cause:"`, or — for direct
`default_draft_fn/4` test callers passing a bare string — falls back to prefixing it with `"Gate
verdict: "`).

**Failure evidence fallback — `failure_summary/1`**: the child's LAST `{"type":"result"}` envelope does
NOT always carry a `result` key — `mix codegen.loop`'s result-line writer always emits `terminal_reason`

- `subtype` (`loop_failed`/`error` on failure, `loop_committed`/`success` on success) but only sometimes
  emits a human `result` string. Both failure-evidence readers — `emit_failure_diagnostics/4` (operator
  stderr) and `default_draft_fn/4` (the `result_text` fed into the draft prompt) — share one extractor,
  `failure_summary/1`: prefers a non-empty `result`, falls back to `"terminal: <reason> (<subtype>)"` when
  `result` is absent, and only returns `""` when the envelope carries neither. Without this fallback a
  `loop_failed` exhaustion with a `clear` gate verdict (the pre-commit re-gate case: gate passed, a later
  tree edit invalidated it) surfaced as "gate: clear, result: (empty)" to both the operator and the
  auto-drafter — undiagnosable. `gate_verdict_fn`'s own read is untouched; this only adds the missing
  reason beside it.

## Boot-Time Decode-Dep Force-Load — `:load_deps_fn`

`mix codegen.loop.queue` starts no application (`mix.exs` `def application do [] end`) and nothing in
`lib/` eager-loads a dep — `:jason` loads lazily, on the drain's FIRST `Jason.decode` call. The drain
shells one child per pitch via `codegen-build`, sharing the SAME `_build` the parent runs in. A child's
`make test` mid-flight stale-`_build` auto-heal (see `e267faba`) recompiles that shared `_build`, which
can churn `:jason`'s beam on disk in the parent's lazy-load window. If the parent's first decode call
lands on a failure/verification path AFTER that churn, `Jason.decode` raises `UndefinedFunctionError` —
not a `Jason.DecodeError` (the decode call already tolerates malformed JSON via the tuple form and
filters non-matching lines; the module being UNLOADED is a different failure mode entirely) — and the
raise is uncaught, taking down the entire drain (`drain/1`) over one child's cost-accounting line.

Fix: `drain/1` force-loads `:jason` via `:load_deps_fn` (default `&Code.ensure_loaded/1`) as the FIRST
`with` clause — before the orphan scan, publish preflight, or lock acquisition, and before any child
spawns. A loaded module is RESIDENT in the VM and survives its on-disk beam being replaced by a
concurrent recompile (probed: load, delete the beam file, decode still succeeds) — so one boot-time load
immunizes every downstream `Jason.decode` call the drain makes (5 sites: spend accounting, call output,
gate verdict, gate base-sha, terminal marker — the last three are on the ship-verification path, so an
unloaded `:jason` doesn't just mis-count cost, it blinds the drain to whether a pitch actually shipped).
A genuinely unloadable dep (corrupt/partial `_build`) aborts the drain LOUD, `{:error, reason}`, BEFORE
any spawn — zero spend, remediation named (`mix deps.get && mix compile`). See `ensure_decode_deps/1`.

## Interrupted-Cycle Recovery (Queue Startup)

`drain/1`'s `with`-chain recovers a killed cycle's stranded `building/*.md` claim right after
`ensure_decode_deps` + `refuse_if_build_orphan` + `BuildLock.acquire(lock_path, "queue", pid_alive_fn)`,
and BEFORE `publish_preflight_fn`, logging GC, ready ordering, blocked-bucket reads, or any child spawn —
`InterruptedCycleRecovery.reconcile/1` (`context/loop.md` § Interrupted-Cycle Recovery) is the shared
engine; this is only its queue-specific call site. A `reconcile` error short-circuits the `with` before
`publish_preflight_fn` ever runs — no network reachability probe, no spawn, on an ambiguous or malformed
recovery state. `reconcile_opts/5` forwards resume-checkpoint test seams (`cycle_state_get_fn`,
`cycle_state_slug_fn`, `read_verdict_fn`, `gate_result_base_sha_fn`, `gate_tree_match_fn`,
`resume_work_present_fn`) already present in the caller's opts alongside the drain's own resolved
`cwd`/`ready_dir`/`building_dir`/`roles` — without this, a hermetic drain test cannot select either the
resume or clean-full-run recovery branch via stubs.

The resolved recovery result is carried in drain state as `state.recovery` — DISTINCT from the
pre-existing per-pitch failure-evidence map's own `recovery` key (the parked-branch string written by
`write_demotion`/`format_failure_row` on a deterministic-failure demotion); the two never collide,
different maps, different lifecycles. Both `{:ok, {:resume, slug}}` and
`{:ok, {:requeued, slug, recovery}}` feed `prioritize_recovered_slug/2`, which reorders the ready-slug
list so the recovered slug spawns FIRST regardless of mtime order — a no-op when the slug isn't in the
ready list (e.g. its claim vanished between recovery and ordering). `{:ok, :none}` leaves ordinary
ordering untouched.

## Trigger Keywords

LoopQueueDrain, queue drain, codegen.loop.queue, --queue, build-queue.sh, ordered_slugs, blocks_on, transient?, watchdog timeout, pitch_budget_secs, CODEGEN_BUILD_QUEUE_BUDGET_USD, CODEGEN_BUILD_QUEUE_PITCH_BUDGET_SECS, CODEGEN_BUILD_QUEUE_MAX_CONSECUTIVE_FAILS, circuit breaker, queue-fail branch, handle_exit_zero, false-0, ship verification, terminal marker, terminal-state.json, terminal_marker_fn, blind retry, deterministic exhaustion, draft_fn, skeleton draft, document-system-prompt, drafted_count, publish, git_publish_fn, publish_preflight_fn, publish_or_halt, recovery branch, park_published_commit, unpublished commit, git push, git rebase, babysit push, watched node, exit 4, dirty_tree_exit_code, handle_exit_dirty_retired, building/, claim_pitch, possession, ship-with-warning, auto-demotion, build_failures, demoted_from, demote_reason, status SHAPING, Build failure history, record_build_failure, write_demotion, write_build_failures, build_failure_evidence, format_failure_row, failure_owner_phase, escape_history_cell, truncate_summary, resolve_pitch_path, dependents_of, CODEGEN_BUILD_QUEUE_MAX_PITCH_FAILS, max_pitch_fails, demote pitch back to draft, load_deps_fn, ensure_decode_deps, Jason unloaded, UndefinedFunctionError, boot-time force-load, Code.ensure_loaded, decode dep, resident module, beam churn, stale \_build queue crash, failure_summary, terminal_reason fallback, empty result evidence, undiagnosable exhaustion, gate clear result empty, classify_drain_failure, format_failure_block, ship_not_verified, transient_exhausted, gate_failed, failure cause, stale clear verdict, contradiction warn, failure block, InterruptedCycleRecovery, queue startup recovery, prioritize_recovered_slug, state.recovery, reconcile_opts, stranded building claim
