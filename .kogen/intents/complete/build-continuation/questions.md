# Questions and choices

No open questions. Decisions: DIRECTION rules 43, 44, 47, 49, 51; EXE-04; lesson 27. Numbers in brackets are the
original package's Assumed items.

## Assumed

1. Continuation is the same command, not a flag (EXE-04). While the slug's continuation set is non-empty (an owner
   record whose current report is `provider`, `interrupted` or `publication-interrupted`), a fresh Build never
   starts: it is continued or refused, and the refusal names its next action (usually remove, then rebuild). [2]
   Reason: rule 44 (loud, never silent). A silent fresh start would strand the kept work.
   Undo: start fresh and leave the old Candidate kept.
2. Budgets carried over: the attempt number, `offline_retries − offline_failures` and `verification_retries −
   failures_since_pass` (from the report's `budget_state`, landed with build-reconcile), and the attempt's
   `guard_violations`.
   Earlier receipts are discarded; verification, Jev and Review all run again. [10]
   Reason: rule 49 ("no continuation after exhausted budgets"); a receipt from before the controller died has no
   verified custody.
   Undo: reset the budgets on continuation.
3. A Candidate whose current report is `publication-interrupted` is never continued: the same-slug rerun is refused
   `publication-started` (inspect: fast-forward yourself or discard). A published one never reaches the decision:
   `check_complete_absent/2` rejects the slug before the lock (build-reconcile's test "a published publication crash is
   rejected for its slug and removable after reconcile"). [11]
   Reason: the record is `accepted`; continuing would re-run an accepted Candidate or commit twice.
   Undo: continue from the Review verdict.
4. No paid target; every proof is offline. EXE-04's acceptance signal (one real-provider observation of
   exact-session continuation after controller exit) is not taken. [13]
   Reason: DIRECTION rule 49 (2026-09-26, later than EXE-04): "no paid target (continuation uses the existing
   session-resume mechanism, provable with the fake harness)". Every in-Build resume is already a new harness process
   started after the one that created the session exited (`codex exec resume <id>` / `claude --resume <id>` in the
   Candidate's harness home; probed argv `exec resume … --json developer-session -`). Continuation changes only which
   controller process makes that call, with the same kept harness home. Claude logins are revoked (rule 51).
   Undo: add `live-reviewer-rework` for provider-stop-continues, with its catalog target and live-test paths guarded
   and a paid target set.
5. The decision covers every report of the set whatever its `continuable`, so each of the nine refusals is reachable
   and has its own fixture. Two budget conditions are dropped because nothing can produce them (INTENT.md).
   `budgets-exhausted` is kept for a state that settled before the controller died. [16]
   Reason: in the original's round 2, `publication-started` and `no-session` applied only to non-continuable reports
   and could never fire, and `budgets-exhausted` needed a config edit that the clean-worktree check rejects first.
   Undo: evaluate only `continuable` reports and let the others start fresh; drop the three refusals.
6. The decision runs after reconcile and the environment breaker and before the item breaker. [new, from the landed
   order in `Kogen.Build.run/3`: `Reconcile.run/1`, then `admission_breakers/5`]
   Reason: a tripped environment breaker must still refuse first (build_breakers_test.exs test 10, risk
   breakers-provider-rerun); a continuation is not a new try of the package, so the item breaker applies only to a
   fresh Build.
   Undo: decide before both breakers.
7. `interrupted` keeps the table row `rebuild`; a `continuable` interrupted report says `continue`. `provider`
   keeps `provider_wait`. [new]
   Reason: failure_report_test.exs refutes `classify("interrupted") == {"interrupted", "continue"}`, and the landed
   table computes item escalation the same way (row `rebuild`, repeated → `reshape_details`).
   Undo: make the row `continue` and edit those two table tests.
8. Only the first resume of a continuation that answers another session id is `session-lost`; every other "resume
   created a new session" stop stays `provider-failure`. [new]
   Reason: the landed prefix table maps that reason to `provider-failure`, and nothing else changes meaning; a lost
   session is only fatal to continuation.
   Undo: make every such stop `session-lost`.
9. How adoption and the checks are implemented is not specified; the refusal names and message, the record, report
   and owner fields and the fake-harness observations are. [new, rule 43]
   Reason: the original named `Workspace.adopt/2`, `Continuation` and `Verification.initialize/7` arguments, and the
   Reviewer judged shape instead of behaviour (F3).
   Undo: restore the named APIs.
10. Reconcile follows `tracking_build_id`: a killed continuation is reported in its own tracking directory, with
    `build_id` that directory's name and `candidate_build_id` the owner's. [new at 99f93f60]
    Reason: the landed `Reconcile.run/1` reads and writes `<owner build_id>/`, which already holds the earlier report
    after a continuation; `FailureReport.write/3` keeps an existing report, so the killed continuation would be
    reported nowhere and the next rerun would continue from a stale report (risk reconcile-current-directory).
    Undo: leave reconcile on the first directory and refuse a continuation whose owner has `tracking_build_id` and is
    `running` on disk.

## Audit

- Split 2026-09-27 at fa48e817 from the approved `durable-builds-and-failure-reports` (approved at f1d176b0, a
  superseded reference in drafts/). Two Builds of it ended with F1-F5 and F7 open; it was too big for one Build and
  named internal functions, so the Reviewer judged shape instead of behaviour.
- **Re-preflight at e5988718 (2026-09-27).** failure-reports landed at e65392cf and build-breakers at e5988718.
  `shaped_against` is re-baselined to e59887183b588d4000bab6c2c5db0e95f60d7b64.
  - **Split again.** Four behaviour scenarios, ten refusal fixtures, a killed-controller stand-in and the
    publication crash were more than one Build converges on (lesson 27). Reconcile, `budget_state`, `published`, the
    categories `interrupted` and `publication-interrupted`, the `published:` line and the stand-in moved to the new
    sibling Draft `build-reconcile` (part 3, id 2e1d43fa-f61e-45e5-b934-47fc1ab52e00, `bc/build-reconcile/`). This
    package keeps continuation, its nine refusals, `continuable`, `continues`, `session-lost` and
    `tracking_build_id`, and depends on part 3. Order: failure-reports → build-breakers → build-reconcile →
    build-continuation.
  - Re-derived against the landed code and fixed:
    - Reports as landed: no `budget_state`, `continuable`, `continues` or `published` (failure_report_test.exs's
      `assert_report!/4` refutes all four; README.md says reports "deliberately have no continuation, budget,
      publication or `published` fields"); `candidate_build_id` exists and is the continued Candidate's id on a
      continuation's report. The two helper refutations this package lifts are stated with their new expectation.
    - Categories: the table has no class `interrupted` and `counts_toward/1` has no clause for it (part 3 adds it).
      Two table tests refute `{"interrupted", "continue"}` / `{<forbidden>, "continue"}`, hence Assumed 7.
    - `next_action`: `provider` is `provider_wait` (unchanged); the Draft's `continue` applies to `interrupted` only.
    - Admission order in `Kogen.Build.run/3`: `check_complete_absent/2` before `acquire_lock/1`; inside the lock
      `admission_breakers/5` runs the environment breaker then the item breaker in one `with`; part 3's reconcile goes
      first; this package's decision goes between the breakers (Assumed 6).
    - Lock and stale lock: `ProcessCustody.acquire/1` reclaims a dead holder and prints "Reclaimed a stale build lock;
      reaped: …"; `admit_candidate/2` claims the lock with the new tracking id, which a continuation must replace with
      the owner's id (risk lock-names-candidate). `live_lock?/2` checks pid liveness only.
    - Session ids: the record's attempt `developer_session_id` (recorded before the verification resume) and the
      report's `developer_session_id`; a Codex thread id is recorded only after the turn returns (probed: a stand-in
      killed during developer-1 leaves nil).
    - Owner records: the landed fields (INTENT.md "Continuing"); `tracking_build_id` is new.
    - The fixture has no Approved `INTENT.md`: `package-changed` now appends to the Approved `intent.yaml`.
    - `record_path!/1` still asserts one record; `records!/1` comes from part 3. `Kogen.CandidateFixture.records/1`
      exists but drops the build id.
    - The resume prompt reuses `FailureHandoff.first_failure_block/1` (landed with build-breakers) instead of a new
      renderer, and skips a `stop` signature as build-breakers' first prompt does.
    - The READY line of the old stand-in design is dropped: tests synchronise on the fake's `developer-hanging` file.
    - The superseded diff now lives at `.kogen/intents/complete/failure-reports/evidence/`.
  - Every refusal has its own fixture and is reachable with every earlier check passing; every test is enumerated
    with setup, command and exact expected result; wrong_results name smoke tests and fixture shortcuts.
  - Every fixture Build clears `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` (ScriptedBuildFixture.run/2's environment and
    the stand-in's `Port.open/2` env); two earlier Reviews found tests inheriting them from the Developer's session.
  - Existing tests that change: failure_report_test.exs's `assert_report!/4` (two lines) and part 3's
    build_reconcile_test.exs (one expectation), each with its new expectation. build_breakers_test.exs test 10 passes
    unedited by a new path (risk breakers-provider-rerun).
  - Probed at e5988718 in `bc/probe/kogen` (a copy of the clone, deps symlinked; `test/kogen/zz_probe*_test.exs`):
    the provider-stop record, state.json and context.json values and resume argv; a kill -9'd stand-in's record,
    owner, lock and state; offline exhaustion's settled state; build_breakers_test.exs test 10's provider report
    session id (`e9508db9-566c-4329-b3e5-e1ff5e566b60`); a Developer edit reading `.kogen/build.lock` into the
    harness home under the applied write boundary; the `mix run` stand-in failing inside an isolated child and the
    `elixir -pa` stand-in working.
- Validated at e5988718 with plan/tools/validate.exs (the kogen checkout at e65392cf): `:ok`.
- **Audit: re-preflight at 99f93f60 (2026-09-27).** build-reconcile landed at 99f93f60 and ctx-test-temp-paths at
  158a57bf; build-breakers was rebased onto the Shaping audit (6b4376e9) and landed as b775974b, so e5988718 is no
  longer on develop. `shaped_against` is re-baselined to 99f93f6026a75700d374489821f7c3c61096df59. Scenarios stay at
  five; tests are renumbered 1-15.
  - Re-derived against the landed code and fixed:
    - Admission order: `run/3` now runs `with :ok <- Reconcile.run(control), {:ok, breaker_state} <-
      admission_breakers(...)`; the Draft extends it to reconcile → environment breaker → continuation decision → item
      breaker (Assumed 6).
    - Reports: `budget_state` and `published` are landed and asserted by `assert_report!/4` (lines 394-395);
      `continues` and `continuable` are still refuted there (lines 393, 396): those two lines are the helper edit.
      `record_interrupted/8` is the landed reconcile writer; it keeps its arity (a landed test calls it directly).
    - `counts_toward/1` already has `{"interrupted", _} -> nil`, so `session-lost` needs only its table row.
    - Reconcile reads and writes `<owner build_id>/` only: new Assumed 10, test 4 and risk reconcile-current-directory.
    - build_reconcile_test.exs landed with other test names than its INTENT.md: the edited test is "a killed stand-in is
      reconciled by the next fixture Build" (line 206, `next_action` `rebuild` → `continue`, plus `continuable`), and
      every other test is listed by its landed name. It has no `killed!/2`, `report/2` or `tail` helper: this Draft
      copies the landed private helpers by name and defines `killed!/2` as that test's inline sequence.
    - The landed fixture: `:hang`, `:slug`, `add_intent!/3`, `records!/1`, `start_standin!/2`, `await_hanging!/1`
      (atomic hang marker) are reused, not specified again. `run/2` and `start_standin!/2` already clear `KOGEN_ROLE`
      and `KOGEN_HARNESS_HOME`; the Draft says so instead of asking for it. `mix kogen.candidates` is called in
      process. Only `:route`, `codex-alt` and `:new_session_on_resume` are new.
    - `records!/1` does not sort oldest first: records have no `created_at` (`Tracking`'s `initial_record/7`), so it
      sorts by random build id (probed). Every test names new records with `new_ids/2` (risk records-order).
    - The fake writes each invocation's prompt to `developer-invocation-<n>-prompt`; tests read that file. Receipts
      are `verification/attempt-<n>-<token>/receipts/cycle-<k>-<target>.json`, each with `attempt_token` (probed).
    - build_workspace_test.exs's failure-retention matrix has seven stops, not five: `offline-exhausted` and
      `outer-allowance-exhausted` were missing.
    - The owner record is rewritten whole by `Workspace.update_status/3` (risk owner-record-rewrites);
      `Workspace.set_owner_status/3` preserves on-disk fields.
    - The Shaping audit landed (`mix kogen.audit`); `priv/kogen/test-reliability.yaml` has no row for
      failure_report_test.exs or build_reconcile_test.exs, and no test is renamed.
  - Probed at 99f93f60 in `bc2/probe/kogen` (a clone at 99f93f60, deps symlinked; `test/kogen/zz_probe*_test.exs` and a
    probe-only logger in `admission_breakers/5` evaluating the nine checks between the breakers):
    - The whole offline suite (1384 tests, all passing) logged one non-empty continuation set: build_breakers_test.exs
      test 10's Build 4 (session `e9508db9-566c-4329-b3e5-e1ff5e566b60`, `pending`, route `claude`), where every check
      passes, so it continues and stops at readiness (risk breakers-provider-rerun).
    - Each refusal fixture 6-14 reaches its named check first; fixture 3 (killed after a failed cycle) passes all nine.
    - The provider stop: report fields, `budget_state` (4/2, one offline failure, `pending`), resume argv `exec resume …
      --json developer-session -`, two invocations and one fake call; today's same-slug rerun starts fresh and
      publishes a second worktree. Test 5's setup: three invocations, two calls, one `guard_violations` entry
      `["stray.txt"]`, category `provider`. Test 14's replaced `state.json` is read by reconcile (`offline_exhausted`,
      `rebuild`). Appending to the Approved `intent.yaml` changes the digest and leaves control clean; `codex-alt`
      resolves the same credential bindings as `codex` in one fixture.
    - With `:route`, `codex-alt` and `:new_session_on_resume` added to a copy of the fixture, every ScriptedBuildFixture
      user (84 tests in seven files) passes, and `fail_first: [1]` with `new_session_on_resume` stops as
      `provider-failure` with "resume created a new session (expected developer-session, got developer-session-2)".
  - Every proof is offline; no paid target.
- Opus review at 99f93f60: not ready (unused other!/3 helper; owner status must be set back to running) → both fixed by the orchestrator; readiness citation, temp dir, next_action contradiction and test wording notes applied. validate.exs at 99f93f60 package level: :ok.
