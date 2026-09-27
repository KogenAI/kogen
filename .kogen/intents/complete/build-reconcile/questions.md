# Questions and choices

No open questions. Decisions: DIRECTION rules 43, 44, 49, 51; EXE-04; lesson 27. Numbers in brackets are the
original package's Assumed items.

## Assumed

1. A dead Build's report is written by the next admitted `mix kogen.build` of any slug (reconcile, right after the
   lock is acquired and before the breakers). `mix kogen.candidates` stays read-only. [9]
   Reason: a killed controller can't write its own report (original round 1). Holding the lock means every `running`
   owner record of this project is dead (risk reconcile-scope).
   Undo: also reconcile in `mix kogen.candidates`, taking the lock.
2. The category of a dead Build comes from its record's `status` (`accepted` → `publication-interrupted`), never
   from the owner status. [11]
   Reason: the superseded package's final Build tested the owner status (F4), which is `running` in both cases.
   Undo: none; the owner status can't tell them apart.
3. `run/3` keeps rejecting an existing Complete Intent before the lock. A controller that died after the
   fast-forward is therefore reconciled by the next Build of another slug, and `mix kogen.candidates` names it
   read-only (`published:`) until then. [11]
   Reason: moving reconcile ahead of the Complete-Intent check (original round 2, Sol) would take the lock for a
   request that is invalid on its face; the commit is already on the admitted branch, so only removal is left.
   Undo: reconcile before `check_complete_absent/2`, taking the lock early.
4. `budget_state` is recorded at every stop (in the report and the stopped attempt) and by reconcile, from the
   attempt's `context.json` and last persisted `state.json`, bound by `state_sha256`. Settlement is unchanged. It has
   no `outer_resumptions` key (the superseded text had one): neither the record nor `context.json` freezes that
   allowance, and nothing reads it. [15, the budget part]
   Reason: `verification_state` exists only after settlement, which a provider stop or a killed controller after a
   pending cycle never reaches (original round 2, Opus; probed at e5988718). build-continuation carries the counts.
   Undo: drop `budget_state`; build-continuation then resets the budgets.
5. `interrupted` reports say `next_action` `rebuild` in this part. build-continuation turns that into `continue`
   for a report it can continue, the way `rebuild` becomes `reshape_details` for a repeated item signature.
   Reason: until part 4 lands, a rerun starts a fresh Candidate; `continue` would be false.
   Undo: write `continue` now and accept a false next action until part 4.
6. Tests trigger reconcile with a Build of a second Approved Intent in the same fixture (`add_intent!/3`,
   `run(dir, slug: …)`), never by calling a reconcile function. [new, rule 43]
   Reason: "the next admitted Build of any slug reconciles" is then observed as behaviour, and part 4's same-slug
   continuation doesn't change these tests.
   Undo: expose and call a reconcile function directly.
7. No paid target; every proof is offline. [13]
   Reason: rule 49 ("no paid target"); the stand-in, ProcessCustody and the fake harness observe everything here.
   Undo: none needed.

## Audit

- Re-preflight at e5988718 (2026-09-27), from the build-continuation Draft shaped at fa48e817. failure-reports landed
  at e65392cf and build-breakers at e5988718. The Draft was too big for one Build (four behaviour scenarios, ten
  refusal fixtures, a stand-in and the publication crash; lesson 27), so it is split: this package (part 3) takes
  reconcile, `budget_state`, `published`, the categories `interrupted` and `publication-interrupted` and the
  `published:` line; build-continuation (part 4) keeps continuation, its refusals, `continuable`, `continues`,
  `session-lost` and `tracking_build_id`. Order: failure-reports → build-breakers → build-reconcile →
  build-continuation.
- Re-derived against the landed code (e5988718):
  - `Kogen.Build.run/3`: `check_complete_absent/2` before `acquire_lock/1`; then `admission_breakers/5`
    (`Breakers.environment_state/1` → `maybe_probe_environment/3` → `Breakers.item_refusal/4`) inside the lock;
    `Tracking.new/5` in `do_build/6`; `admit_candidate/2` claims the lock with the new build id.
  - `FailureReport`: the table (17 rows, no class `interrupted`), `classify/1`, `counts_toward/1` (its `case` has no
    clause for a new class), `write/3` (temp file, `:file.make_link/2`, `{:error, :eexist}` keeps the existing
    report), `record_failure/4` (fields as landed; `candidate_build_id` from `ctx.candidate`; signature order
    failure_signatures → unchanged_candidate → cycle_signatures → `for_stop/2`). Landed reports have no
    `budget_state`, `continuable`, `continues` or `published`; failure_report_test.exs's `assert_report!/4` refutes
    all four, and README.md says so.
  - `stop/3` computes the category once, records the attempt, writes the report, then `retained/2` sets the owner
    status; `refuse_publication/4` writes `accepted-unpublished`.
  - `Workspace`: owner record fields (`schema_version`, `build_id`, `intent_id`, `slug`, `title`, `control_root`,
    `worktree_path`, `branch`, `admitted_branch`, `admitted_commit`, `harness_home`, `credential_bindings`,
    `started_at`, `status`, `candidate_commit`), `list/1`/`effective_status/2`/`live_lock?/2` (pid-only liveness),
    `remove/3`'s `reachable/3`, `fast_forward/2`, `remove_published/1`, `retained_description/2`.
  - `Kogen.ProcessCustody.acquire/1` prints "Reclaimed a stale build lock; reaped: …"; `claim/2` sets the build id.
  - mix kogen.candidates prints `report:   none` (three spaces) without a report, `class:`/`next:`/`report:  <path>`
    with one.
- Probed at e5988718 in a copy of the clone with deps symlinked (`bc/probe/kogen`, probe tests
  `test/kogen/zz_probe_test.exs` and `zz_probe2_test.exs`):
  - provider stop (fail_first [1], provider_fail developer-2): attempt number 0, the attempt keys listed in
    INTENT.md "Why", state.json `offline_failures` 1 / `failures_since_pass` 0 / `terminal_state` `pending` at
    `verification/attempt-0-<token>/state.json`, context.json `offline_retries` 4 / `verification_retries` 2, the
    resume argv `exec resume … --json developer-session -`; a rerun today gets a fresh Candidate and publishes;
  - fail_all [1]: `offline_failures` 5, `terminal_state` `offline_exhausted`, category `offline-exhausted`;
  - a stand-in killed by `kill -9` while hanging in developer-2 or developer-1: record `pending`, owner `running`
    on disk and `stopped: interrupted` in `Workspace.list/1`, lock left, fake reaped, no report; the next Build
    printed "Reclaimed a stale build lock; reaped: no live groups" and published; with developer-1 the attempt has
    `developer_session_id` nil and state.json has no `offline_failures`;
  - the stand-in as `mix run` inside an IsolatedCase child tried to compile into the child's empty `_build` (failed
    on yamerl in the copy); as `elixir -pa <code paths>` it ran in seconds.
- Every fixture Build clears KOGEN_ROLE and KOGEN_HARNESS_HOME (two earlier Reviews found tests inheriting them).
- Opus review at e5988718: not ready (published-line format/indent and negative checks; hang-file pid race) → fixed by the orchestrator (exact indented line after path:, anchored regexes, temp+rename pid, parseable-pid wait, moduletag timeout, on_exit cleanup); notes added.
