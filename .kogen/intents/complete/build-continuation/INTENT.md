# Continue interrupted Builds with the same command

Shaped against develop 99f93f60 (99f93f6026a75700d374489821f7c3c61096df59), where `failure-reports` (e65392cf),
`build-breakers` (b775974b), `ctx-test-temp-paths` (158a57bf) and `build-reconcile` (99f93f60,
`.kogen/intents/complete/build-reconcile/`) have landed. Part 4 of 4 of the split of durable-builds-and-failure-reports.
The previous baseline e5988718 is not on develop: build-breakers was rebased onto the Shaping audit (6b4376e9) and
landed as b775974b.

This package specifies what a rerun must continue, refuse, report and print. How build.ex, `Kogen.Build.Reconcile`,
`Kogen.Build.Workspace` and the report module do it is up to the Developer; `lib/kogen/build/continuation.ex` is
guarded in case the Developer wants a separate module. Function names below describe the code at 99f93f60.

## Launch

```sh
mix kogen.build --route codex build-continuation
```

Every proof is offline (DIRECTION rules 49, 51).

## Why (the code at 99f93f60)

- A Candidate is never continued. `Workspace.create/2` refuses every existing path ("already exists and is never
  reused"), and `admit_candidate/2` always creates one. A rerun after a provider stop or a killed controller starts a
  fresh Candidate and a fresh Developer session (probed at 99f93f60: after a `provider` stop the rerun of the same slug
  created a second record and worktree, published it and left the first Candidate `stopped: provider`), throwing the
  kept work away (EXE-04; rule 49: "provider-down stops … and continues on rerun"; "no continuation after exhausted
  budgets (rebuild)").
- The report of a `provider` stop already says `next_action` `provider_wait` and carries `developer_session_id`,
  `record_sha256`, the signature (the attempt's `cycle_signatures` entry, saved before the resume) and build-reconcile's
  `budget_state`. build-reconcile's `Kogen.Build.Reconcile.run/1` reports a killed controller as `interrupted` with
  `next_action` `rebuild`. Nothing reads any of it back.
- The `Kogen.Build.Tracking` moduledoc says "Records are evidence only; this module never reloads one as Build
  state", and every record says `"purpose": "inspection evidence; not a recovery checkpoint"`.

## Outcome

### Report fields and one category

Every report (failure-reports' `FailureReport.record_failure/4` and build-reconcile's
`FailureReport.record_interrupted/8`) gains two keys, always present:

- **`continuable`**: true exactly for a report with category `provider` or `interrupted` that has a
  `developer_session_id` and whose `budget_state` is null or has `terminal_state` `pending` or `provider`.
- **`continues`**: null, or on a continuation's own report the `continues` value of its record (below).

An `interrupted` report that is `continuable` has `next_action` `continue`; any other `interrupted` report keeps
`rebuild`. The table row stays `{"interrupted", "rebuild"}` (the way an item row stays `rebuild` and a repeated
signature turns it into `reshape_details`). `provider` keeps `provider_wait`.

One row joins the table in `lib/kogen/build/failure_report.ex` (the landed `counts_toward/1` clause
`{"interrupted", _} -> nil` already covers it):

| category | class | next_action | counts_toward |
| --- | --- | --- | --- |
| `session-lost` | `interrupted` | `rebuild` | null |

`FailureReport.record_interrupted/8` keeps its arity and argument order (build_reconcile_test.exs calls it directly).

### The continuation set and the decision

`Kogen.Build.run/3` at 99f93f60, inside the lock, runs `Reconcile.run(control)` and then
`admission_breakers(control, slug, intent, config, approved_entries)`, which checks the environment breaker
(`Breakers.environment_state/1`, `maybe_probe_environment/3`) and then the item breaker (`Breakers.item_refusal/4`).
This package extends that order to: **reconcile → environment breaker → continuation decision → item breaker**. The
item breaker runs only when the decision starts a fresh Build.

An owner record's **current tracking directory** is `.kogen/runtime/scenario-tracking/<tracking_build_id>/` when the
owner record has `tracking_build_id` (below), otherwise `…/<build_id>/`. Its current report and record are the
`failure-report.json` and `record.json` there; reports in earlier tracking directories of the same Candidate are
history and are never read by the decision.

**Reconcile reads the current tracking directory.** `Reconcile.run/1` reads a dead owner's current record and report
(not always `<build_id>/`). A report it writes for a killed continuation is written in that directory with `build_id`
the directory's name, `candidate_build_id` the owner's `build_id` and `continues` the record's `continues`; for an owner
without `tracking_build_id` it writes what it writes at 99f93f60 plus `continuable` and `continues` (null), except that a
continuable `interrupted` report's `next_action` is `continue`.

The slug's **continuation set** is every owner record of this slug (after reconcile) whose current report has category
`provider`, `interrupted` or `publication-interrupted`, whatever its `continuable`. Every other category,
`session-lost` included, is outside the set: those Candidates stay kept and a fresh Build gets a new Candidate, as
build_workspace_test.exs's failure-retention matrix asserts. With an empty set a fresh Build starts (after the item
breaker), exactly as today.

Otherwise these checks run in order, and the first that fails refuses the Build:

1. `ambiguous`: the set holds two or more owner records.
2. `record-changed`: the current record's bytes differ from the report's `record_sha256`, or (when `budget_state` is
   not null) the bytes of the file at `budget_state.state` differ from `budget_state.state_sha256`.
3. `publication-started`: the report's category is `publication-interrupted`.
4. `no-session`: the report has no `developer_session_id` (a controller killed during its first Developer turn).
5. `package-changed`: the report's `approved_package_digest` differs from `Tracking.approved_digest/1` of the Approved
   entries this run read (the value `admission_breakers/5` already computes for the item breaker).
6. `control-moved`: control is not on the owner's `admitted_branch`, or that branch's commit differs from the owner's
   `admitted_commit`.
7. `route-changed`: the resolved route's name differs from the current record's `route.name`, or the resolved
   credential bindings (as `Kogen.Harness.binding_record/1` writes them, in `binding_records/1`'s order) differ from the
   owner's `credential_bindings`.
8. `candidate-missing`: the worktree, the Candidate branch or the harness home is gone, the Candidate's HEAD differs
   from `admitted_commit`, or the Candidate's Approved copy differs from the Approved entries this run read.
9. `budgets-exhausted`: `budget_state.terminal_state` is `exhausted`, `offline_exhausted` or `environment`. Only an
   `interrupted` report can carry one: the controller died after a settled state was persisted and before its stop.

Two budget conditions are not checked, because nothing at 99f93f60 produces them: a remainder below 0 (the budgets
are frozen into the attempt's `context.json` and `Verification` settles the moment a count passes its budget), and an
attempt number above `outer_resumptions` (`rework/4` stops before a new attempt once `number >= outer_resumptions`,
and `.kogen/config.yaml` is tracked, so check 6 and `check_clean_worktree/1` keep it at `admitted_commit`).

**A refusal** is returned before `Tracking.new/5`, so it writes no record, no report, no owner record, no worktree and
no harness home, launches nothing, and changes nothing in the kept Candidate. Its message is exactly

```text
Continuation refused (<name>): <detail>; <retained description>; next action: <action>
```

- `<detail>` says what differed, in one clause.
- `<retained description>` is `Workspace.retained_description/2` of the kept Candidate ("Candidate kept: slug …,
  build id <owner build_id>, worktree …, branch …, harness home …; remove it with `mix kogen.candidates.remove
  <id>`"), with `discard_accepted: true` for `publication-started`.
- `<action>` is `remove the Candidate, then rebuild` by default; ``rerun with `--route <old route name>` `` for
  `route-changed`; and ``inspect: fast-forward <admitted branch> to the Candidate commit yourself, or `mix
  kogen.candidates.remove <id> --discard-accepted` `` for `publication-started`.

While the set is non-empty, a fresh Build of that slug never starts.

### Continuing

If every check passes, the rerun continues the one Candidate of the set:

- **A new tracking record.** `Tracking.new/5` writes it as today, plus a top-level `continues`:
  `{"build_id": <the current tracking directory's name>, "record_sha256": <the report's>, "category": <the
  report's>}`. The earlier record and report are never changed. The record's `purpose` string stays as it is
  (scenario_tracking_test.exs asserts it).
- **The old Candidate.** No worktree, branch, harness home or owner record is created. The owner record keeps its
  `build_id`, `worktree_path`, `branch`, `harness_home`, `admitted_branch`, `admitted_commit`, `credential_bindings`
  and `started_at`, and gains `tracking_build_id` = the new record's build id. `Workspace.update_status/3` rewrites
  the owner record from the candidate map (`write_owner/4`'s fixed field list), so `tracking_build_id` must survive
  every later status write (the stop's `retained/2`, `Workspace.set_owner_status/3`). While the Build runs,
  `.kogen/build.lock` names the owner's `build_id` (`ProcessCustody.claim/2` with it, not with the new record's id),
  and before the first launch the continuation sets the owner record's status to `running` (keeping every other field,
  including `tracking_build_id`, e.g. via `Workspace.update_status/3` extended to carry `tracking_build_id`, or
  `set_owner_status/3`). Only a `running` status on disk makes `effective_status/2` report `running` and makes
  `Reconcile` act on the owner if this continuation is killed in turn; `live_lock?/2` alone does not. The report of any stop of the continuation is written in
  the new tracking directory with `build_id` the new record's id and `candidate_build_id` the owner's `build_id`, and
  the stop sets the one owner record's status as usual. Publication removes the Candidate and its owner record as
  usual (`Workspace.remove_published/1`).
- **Admission as today.** `run_in_candidate/2` runs as usual: the boundary, `record_candidate/3`, verification preflight
  (`preflight_candidate/1`), a fresh guarded-paths snapshot of the unchanged HEAD tree (`capture_candidate/1`), the
  base workspace and `open_roles/1`. Then `begin_attempt/4` starts the attempt with the old attempt's `number` and the
  old `developer_session_id`, so the first Developer invocation (`launch_attempt/4`) is a resume of that session.
- **Carried budgets**, only from the report's `budget_state`: `offline_retries − offline_failures` and
  `verification_retries − failures_since_pass` replace the configured values (`retry_budgets/1`) for the continued
  attempt's `Verification.initialize/7`. A null `budget_state` carries the configured values. A later attempt of the
  same Build (after a Review rework) gets the configured values, as every new attempt does today.
- **Carried guard reworks.** The continued attempt starts with the old attempt's `guard_violations`, so
  `guard_rework/6`'s allowance (`@guard_reworks` 2) is not reset.
- **No receipt reused.** The continued attempt gets a new attempt token and its own verification directory, runs full
  verification, Jev and a fresh Review, and every receipt carries the new token.
- **The resume prompt** is `developer_prompt/2`'s form (`render_developer_prompt/5`, then the block, then
  `task_context/3`) with `resume_feedback/2` replaced by a continuation block: the line `Continuing Build <old build
  id> after it stopped (category: <category>; record: <absolute path of the old record.json>).`, then the sentence
  `Receipts from before this continuation are discarded: the controller verifies the Candidate again after your turn,
  and a fresh Reviewer reviews it.`, then `FailureHandoff.first_failure_block/1` of the report's signature when that
  signature's `source` is not `stop` and its `target` is a string (the rule `first_failure_prompt_block/1` applies).
- **Session lost.** When that first resume answers with another session id (`receive_developer/4`'s "resume created a
  new session" branches), the Build stops as `session-lost` (`next_action` `rebuild`), not as `provider-failure`.
  Every other "resume created a new session" stop keeps today's `provider-failure` (the `@stop_categories` prefix row).

### Visible in `mix kogen.candidates`

`report_line/1` (the `class:`, `next:` and `report:` lines) reads the owner's current report (`tracking_build_id` when
set). Every other line, build-reconcile's `published:` line included, is unchanged.

### Documentation

- README.md's "Failure reports" section documents continuation, the continuation set, the nine refusals,
  `continuable`, `continues`, `session-lost` and `tracking_build_id`, and replaces "Continuation fields are added by
  the build-continuation feature." It names only files and `Module.fun/arity` that exist (readme_guidance_test.exs).
- `Mix.Tasks.Kogen.Build`'s moduledoc says a rerun continues a Candidate of the continuation set or refuses.
- The `Kogen.Build.Tracking` moduledoc says that only continuation reads an earlier record, bound by the report's
  `record_sha256`, for its session id, attempt number, `route` and guard violations, and never writes it.

## Tests the Developer writes

`test/kogen/build_continuation_test.exs` (new; `use Kogen.IsolatedCase, async: true`; `@moduletag timeout: 600_000`
as build_breakers_test.exs has, which changes no Build or gate timeout). Command:
`mix test test/kogen/build_continuation_test.exs`, and `make check`. Every test uses its own
`ScriptedBuildFixture.fixture!()` control (codex protocol, session `developer-session`, `offline_retries: 4`,
`verification_retries: 2`, `outer_resumptions: 3`, slug `scripted-build`, default route `codex`) and the landed fixture
helpers: `run/2`'s `:hang` and `:slug`, `add_intent!/3`, `records!/1`, `start_standin!/2` and `await_hanging!/1`.
Every test that starts a stand-in registers an `on_exit` that kills it, as build_reconcile_test.exs does.

Helpers, copied from build_reconcile_test.exs's private helpers with the same names and bodies: `provider_stopped!/1`
(`Fixture.run(dir, fail_first: [1], provider_fail: ["developer-2"], provider_tail: tail)` returns `{:error, m}` with
`m =~ "category: provider"`; returns P's `{id, path, record}`), `owner!/2`, `tree!/1`, `wait_gone!/2`,
`sha/1`, `rewrite_record_status!/3`, `rewrite_owner_status!/3`, `git!/3` and `git_env/0` (not `other!/3`, which no test
here calls: an unused `defp` fails the `--warnings-as-errors` test compile); `tail` is the `output` of
`test/support/provider_tails/be_n9crq_claude_session_limit.json`. New in this file:

- `killed!(dir, opts)`: the sequence of build_reconcile_test.exs "a killed stand-in is reconciled by the next fixture
  Build": `Fixture.start_standin!(dir, opts)` with its `on_exit`, `Fixture.await_hanging!(dir)` (the fake's pid),
  `kill -9` of the stand-in's OS pid, then `wait_gone!/2` of the stand-in and of the fake.
- `new_ids(dir, before)`: the build ids of `Fixture.records!(dir)` not in `before`. A record has no `created_at`, so
  the landed `records!/1` sorts by build id only (probed at 99f93f60: a rerun's record sorted before the first
  Build's); tests never rely on its order and name a record by the ids taken before the command (C is the one new id;
  C1, C2 likewise).
- `report(dir, id)`: the decoded `FailureReport.report_path(dir, id)`.
- `invocations(h)`: the integer in `<h>/fake-state/developer-invocations`; `state(h, name)`: `<h>/fake-state/<name>`
  (the fake writes `developer-invocation-<n>` (argv) and `developer-invocation-<n>-prompt`). `h` is P's
  `harness_home`, kept after publication.
- `attempt_context(record)`: the decoded `content_base64` of the last attempt's `verification_context`.

### Continuing

1. **"a provider-stopped Build continues its Candidate and Developer session and publishes"**
   - Setup: `provider_stopped!(dir)` (P; report `r1`, record bytes `b1`). Precondition: `r1` has `continuable` true,
     `continues` nil, `next_action` `provider_wait`, `developer_session_id` `developer-session`, and
     `invocations(h) == 2`.
   - Command: `Fixture.run(dir, edits: %{2 => "cat '<dir>/.kogen/build.lock' > \"$KOGEN_HARNESS_HOME/lock-seen.json\""})`
     (the continued turn is the fake's call 2: P's verification resume never reached the call counter).
   - Expected:
     - `:ok`; `new_ids(dir, [P])` is `[C]`, with C's `continues` equal to `%{"build_id" => P,
       "record_sha256" => r1["record_sha256"], "category" => "provider"}`, C's `status` `accepted`, C's `candidate`
       block naming P's `worktree_path`, `branch` and `harness_home`, and C's first attempt with `number` 0,
       `developer_session_id` `developer-session` and an `attempt_token` different from P's;
     - `invocations(h) == 3`; `state(h, "developer-invocation-3")` matches `~r/^exec resume .* developer-session -$/`;
       `state(h, "developer-invocation-3-prompt")` contains `Continuing Build <P> after it stopped (category: provider;
       record: <dir>/.kogen/runtime/scenario-tracking/<P>/record.json).`, the sentence `Receipts from before this
       continuation are discarded: the controller verifies the Candidate again after your turn, and a fresh Reviewer
       reviews it.` and `FailureHandoff.first_failure_block(r1["signature"])`, and does not start with `Controller
       verification failed after your turn`;
     - `<h>/lock-seen.json` decodes with `build_id` P;
     - `attempt_context(C)` has `offline_retries` 3 and `verification_retries` 2;
     - at least one file under `<dir>/.kogen/runtime/scenario-tracking/<C>/verification/attempt-0-<C token>/receipts/`,
       and every one decodes with `attempt_token` equal to C's token;
     - `state(h, "reviewer-prompt-1")` exists (Review ran);
     - control's `main` holds `.kogen/intents/complete/scripted-build/`, and `Workspace.list(dir) == []`;
     - P's report and record bytes are still `r1`'s and `b1`.
2. **"a continuation that stops again is named by the one owner record and continues again"**
   - Setup: `provider_stopped!(dir)` (P, report `r1`).
   - Command 1: `Fixture.run(dir, provider_fail: ["developer-3"], provider_tail: tail)`.
   - Expected 1: `{:error, message}` containing `category: provider` and `Candidate kept: slug scripted-build, build id
     <P>`; `new_ids(dir, [P])` is `[C1]`; the only owner record is P's file, with `tracking_build_id` C1, `status`
     `stopped: provider` and `worktree_path`, `branch`, `harness_home`, `admitted_commit`, `credential_bindings` and
     `started_at` equal to P's; `report(dir, C1)` has `build_id` C1, `candidate_build_id` P, `continues`
     `%{"build_id" => P, "record_sha256" => r1["record_sha256"], "category" => "provider"}`, `continuable` true, a
     `signature` whose `source` is `stop`, and `budget_state` with `outer_attempt` 0, `offline_retries` 3,
     `offline_failures` 0 and `terminal_state` `pending`; `mix kogen.candidates` (`capture_io`, cwd `dir`) prints
     `report:  <path of report(dir, C1)>` and not `report:  <path of r1>`.
   - Command 2: `Fixture.run(dir)`.
   - Expected 2: `:ok`; `new_ids(dir, [P, C1])` is `[C2]`; C2's `continues` is `%{"build_id" => C1, "record_sha256" =>
     report(dir, C1)["record_sha256"], "category" => "provider"}`; `attempt_context(C2)` has `offline_retries` 3;
     `state(h, "developer-invocation-4")` matches `~r/^exec resume .* developer-session -$/` and its prompt contains
     `Continuing Build <C1> after it stopped (category: provider;` and no `## First failure` (C1's signature is a
     `stop` signature); the P and C1 reports and records are byte-identical to before Command 2.
3. **"a killed controller's Candidate is reconciled and continued by the rerun"**
   - Setup: `killed!(dir, fail_first: [1], hang: ["developer-2"])` (P, record bytes `b1`).
   - Command: `capture_io` of `Fixture.run(dir)`.
   - Expected: output contains "Reclaimed a stale build lock"; the result is `:ok`; `report(dir, P)` has `category`
     `interrupted`, `continuable` true, `next_action` `continue`, `continues` nil, `developer_session_id`
     `developer-session` and `record_sha256` sha(`b1`); the one new record C (`new_ids(dir, [P])`) has `continues`
     `%{"build_id" => P, "record_sha256" => sha(b1), "category" => "interrupted"}`;
     `state(h, "developer-invocation-3")` matches `~r/^exec resume .* developer-session -$/`; `attempt_context(C)` has
     `offline_retries` 3; P's record bytes are `b1`.
4. **"a killed continuation is reconciled in its own tracking directory and continued again"**
   - Setup: `provider_stopped!(dir)` (P, report `r1`); then `killed!(dir, hang: ["developer-3"])` (the stand-in
     continues P and hangs in the continued turn); C1 is `new_ids(dir, [P])`'s one id, with record bytes `c1`.
     Precondition: `owner!(dir, P)` has `status` `running` and `tracking_build_id` C1, `Workspace.list(dir)` shows P
     as `stopped: interrupted`, and C1's tracking directory holds no `failure-report.json`.
   - Command: `Fixture.run(dir)`.
   - Expected: `:ok`; `report(dir, C1)` has `category` `interrupted`, `build_id` C1, `candidate_build_id` P,
     `continues` `%{"build_id" => P, "record_sha256" => r1["record_sha256"], "category" => "provider"}`,
     `developer_session_id` `developer-session`, `continuable` true, `next_action` `continue` and `record_sha256`
     sha(`c1`); `Workspace.list(dir) == []` (the continuation published); P's report is still `r1`'s bytes; the one
     record of `new_ids(dir, [P, C1])`, C2, has `continues` `%{"build_id" => C1, "record_sha256" => sha(c1),
     "category" => "interrupted"}`; `state(h, "developer-invocation-4")` matches
     `~r/^exec resume .* developer-session -$/`.
5. **"carried guard reworks are not reset"**
   - Setup: `Fixture.run(dir, edits: %{1 => "touch stray.txt", 2 => "rm stray.txt"}, fail_first: [2],
     provider_fail: ["developer-3"], provider_tail: tail)`: turn 1 leaves an unguarded file, the guard rework (fake
     call 2) removes it and its cycle fails, and the verification resume (invocation 3) hits the usage limit.
     Precondition: `{:error, m}` with `m =~ "category: provider"`, `invocations(h) == 3`, and P's last attempt has one
     `guard_violations` entry `g1` with `paths` `["stray.txt"]`.
   - Command: `Fixture.run(dir, edits: %{3 => "touch stray.txt"})` (the continued turn is fake call 3).
   - Expected: `{:error, message}` containing `category: guard-violation`; `invocations(h) == 5` (the continued turn
     and one guard rework; without the carried entry there would be a sixth); the last attempt of C
     (`new_ids(dir, [P])`) has three `guard_violations` entries, the first equal to `g1`.

### Refusals

Each of tests 6-14 starts from its own fixture and makes one change, so the named check is the first that fails. For
each, with `n0` = `length(records!(dir))`, `w0` = the `git worktree list --porcelain` output of control, `o0` = the
owner record ids, `i0` = `invocations(h)` and `t0` = `tree!(P's worktree_path)`, all taken after the change:

- the rerun returns `{:error, message}` with `message` starting `Continuation refused (<name>): `, containing
  `Candidate kept: slug scripted-build, build id <P>` (for 6, see there) and ending `; next action: <action>` (the
  default `remove the Candidate, then rebuild` unless stated);
- `length(records!(dir)) == n0`, and the worktree list, owner ids, `invocations(h)` and `tree!` equal `w0`, `o0`,
  `i0` and `t0`; no tracking directory other than those of `records!` exists; `.kogen/build.lock` does not exist
  afterwards;
- a second identical rerun returns a message starting with the same `Continuation refused (<name>): ` and changes none
  of these either.

6. **"a second Candidate in the continuation set is refused as ambiguous"**: from `provider_stopped!(dir)`, copy P's
   owner record to `Workspace.owner_path(dir, x)` with `build_id` `x` (`x` = `copy0000000000000000000A`) and copy P's
   tracking directory to `scenario-tracking/<x>/`. `n0` counts both records. `<detail>` names every build id of the
   set, so the message contains both P and `x`; the retained description is the first owner record's in
   `Workspace.list/1` order, and the test asserts only that the message contains `Candidate kept: slug scripted-build,
   build id ` followed by P or `x`.
7. **"an edited stopped record is refused as record-changed"**: from `provider_stopped!(dir)`, append one space to
   P's `record.json`.
8. **"a Candidate killed during publication is refused as publication-started"**: from `provider_stopped!(dir)`,
   `File.rm!` P's report, `rewrite_record_status!(dir, P, "accepted")` and `rewrite_owner_status!(dir, P,
   "running")`. Before refusing, reconcile writes P's report: `publication-interrupted`, `published` false,
   `next_action` `inspect`, `continuable` false. The message ends ``; next action: inspect: fast-forward main to the
   Candidate commit yourself, or `mix kogen.candidates.remove <P> --discard-accepted` `` and its retained
   description ends with ``remove it with `mix kogen.candidates.remove <P> --discard-accepted` ``.
9. **"a Candidate killed in its first turn is refused as no-session"**: `killed!(dir, hang: ["developer-1"])`. Before
   refusing, reconcile writes P's report: `interrupted`, `developer_session_id` nil, `continuable` false,
   `next_action` `rebuild`.
10. **"an edited Approved package is refused as package-changed"**: from `provider_stopped!(dir)`, append
    `"# edited\n"` to control's `.kogen/intents/approved/scripted-build/intent.yaml` (ignored by Git, so control
    stays clean).
11. **"a moved admitted branch is refused as control-moved"**: from `provider_stopped!(dir)`, commit a new file
    `moved.txt` on control's `main` (with `git!/3` and `git_env/0`).
12. **"another route is refused as route-changed"**: from `provider_stopped!(dir)`, rerun with `route: "codex-alt"`.
    The message ends ``; next action: rerun with `--route codex` ``.
13. **"a removed worktree is refused as candidate-missing"**: from `provider_stopped!(dir)`, `File.rm_rf!` P's
    worktree directory (its registration and branch stay). Instead of the `tree!` check, the worktree directory is
    still absent after both reruns.
14. **"a settled exhausted state is refused as budgets-exhausted"**: `killed!(dir, fail_first: [1], hang:
    ["developer-2"])`; then replace the dead attempt's `state.json` (write a temp file in the same directory, then
    `File.rename!/2`) with the same JSON plus `offline_failures` 5 and `terminal_state` `offline_exhausted` (the
    settled state a `fail_all: [1]` Build reaches). Before refusing, reconcile writes P's report: `interrupted`,
    `budget_state.terminal_state` `offline_exhausted`, `continuable` false, `next_action` `rebuild`.

### Session lost

15. **"a continuation whose resume answers another session stops as session-lost and the next rerun starts fresh"**
    - Setup: `provider_stopped!(dir)` (P).
    - Command 1: `Fixture.run(dir, new_session_on_resume: true)`.
    - Expected 1: `{:error, message}` containing `category: session-lost`; `report(dir, C)` has `category`
      `session-lost`, `class` `interrupted`, `next_action` `rebuild`, `counts_toward` nil, `continuable` false and
      `continues` `%{"build_id" => P, "record_sha256" => …, "category" => "provider"}`; `owner!(dir, P)` has
      `status` `stopped: session-lost` and `tracking_build_id` C.
    - Command 2: `Fixture.run(dir)`.
    - Expected 2: `:ok`; the one record of `new_ids(dir, [P, C])` has `continues` nil and a `candidate`
      `worktree_path` different from P's; `owner!(dir, P)` still says `stopped: session-lost` and P's worktree still exists.
    - Control (a second fixture): `Fixture.run(dir2, fail_first: [1], new_session_on_resume: true)` (the verification
      resume of a fresh Build answers another session) returns `{:error, message}` containing `resume created a new
      session (expected developer-session, got developer-session-2)` and `category: provider-failure`.

## Existing tests and fixtures

Fixtures that change:

- **`test/support/scripted_build_fixture.ex`** (as build-reconcile left it) gains:
  - `:route`, passed to `Kogen.Build.run/3` instead of today's `nil` (default `nil`);
  - a second route `codex-alt` in its `config/1`, identical to `codex` (same harness, profiles and helpers;
    `default_route` stays `codex`);
  - `:new_session_on_resume`: the fake Developer answers thread id `developer-session-2` instead of
    `developer-session` for every invocation whose argv contains `resume`.

  `run/2` already clears `KOGEN_ROLE` and `KOGEN_HARNESS_HOME` (`{"KOGEN_ROLE", nil}`, `{"KOGEN_HARNESS_HOME", nil}`
  in its environment list, landed with build-reconcile), and `start_standin!/2` already unsets both in `Port.open/2`
  (`{~c"KOGEN_ROLE", false}`, `{~c"KOGEN_HARNESS_HOME", false}`); both stay. `mix kogen.candidates` is called in
  process (`Mix.Tasks.Kogen.Candidates.run([])` in `File.cd!/2`), never as a separate `mix` process. Existing callers
  pass none of the new options and see today's behaviour. `test/support/scripted_controller_standin.exs` is unchanged
  (it passes every JSON option through to `run/2`).

Existing tests that change (each keeps its name):

- **`test/kogen/failure_report_test.exs`**: in the private helper `assert_report!/4`, `refute Map.has_key?(report,
  "continues")` and `refute Map.has_key?(report, "continuable")` become `assert Map.has_key?(report, …)`. Nothing else
  changes. The four tests that call it ("two offline exhaustion Builds write final reports and count the same
  signature", "Jev cannot-comply, missing deps, and publication refusal each write their terminal report", "a Claude
  login rejection is an environment stop with one Developer invocation", "usage-limited Developer stop keeps the
  provider class and session") pass with it.
- **`test/kogen/build_reconcile_test.exs`**: in "a killed stand-in is reconciled by the next fixture Build",
  `assert report["next_action"] == "rebuild"` becomes `assert report["next_action"] == "continue"`, and
  `assert report["continuable"] == true` is added after it (the dead Build has session `developer-session` and a
  `pending` budget). Nothing else changes.

These pass unedited (existing-expectations-kept):

- build_reconcile_test.exs's other tests: "provider and exhausted stops persist budget_state in report and record",
  "admission stop has null budget_state and interrupted categories count toward nothing", "publication interruption
  reports inspect or remove according to ancestry" (calls `FailureReport.record_interrupted/8` directly), "reconcile
  reports a dead owner from its record status and is idempotent" (calls `Reconcile.run/1` on a hand-written owner
  without `tracking_build_id`), "a first-turn kill has no Developer session and a stop signature", "an existing
  provider report only repairs the owner status" and "a publication crash before fast-forward is inspectable and not
  published" (their later Builds are of `scripted-other`, whose set is empty), and "a published publication crash is
  rejected for its slug and removable after reconcile" (its same-slug rerun is refused by `check_complete_absent/2`
  before the lock).
- build_workspace_test.exs "a Build stopped by #{category} keeps its Candidate, names it and is never reused by the
  next Build" (its seven stops are `offline-exhausted`, `outer-allowance-exhausted`, `cannot-comply`,
  `guard-violation`, `integrity`, `provider-failure` and `review-failure`; none is in the continuation set, so its
  second Build gets a fresh Candidate) and "a pre-existing Candidate path is refused and never reused"
  (`Workspace.create/2` still refuses every existing path).
- failure_report_test.exs "category table keeps the approved classes and excludes continuation rows" and "the
  category table is exhaustive and exposes counting semantics" (`classify("interrupted")` stays
  `{"interrupted", "rebuild"}` and `classify("session-lost")` is `{"interrupted", "rebuild"}`, neither the refuted
  `{<category>, "continue"}`), and "usage-limited Developer stop keeps the provider class and session" and "failed
  cycle signature is recorded before the resumed Developer stops" (each runs one Build per fixture).
- build_breakers_test.exs, whole. Its only same-slug rerun of a set member is "10. provider reports are skipped while
  the environment run continues": Build 3 stops as `provider`, and Build 4 (the same slug, logged out) now
  **continues** Build 3's Candidate instead of starting fresh. Probed at 99f93f60 with the nine checks instrumented at
  the decision point: Build 3's report has `developer_session_id` `e9508db9-566c-4329-b3e5-e1ff5e566b60`,
  `budget_state.terminal_state` `pending` and route `claude`, and every check passes. Build 4's readiness then fails in
  the kept harness home and it stops as `environment`, writing its report in its own new tracking directory, so
  `[p1, p2, provider, p4] = reports(control)` still holds with four distinct `build_id`s and p4 names
  `mix kogen.claude.login`; Build 5's environment breaker, which runs before the decision, still refuses naming p1, p2
  and p4; `probe_lines(provider_cwd)` stays `[]` (risk breakers-provider-rerun).
- candidates_command_test.exs (its owner records are hand-written without `tracking_build_id`, so `report_line/1`
  reads `<build_id>/`), including build-reconcile's "published interrupted Candidates print the published line and
  remain removable" and "an unmerged interrupted Candidate has no published line and needs discard".
- controller_verification_test.exs, process_custody_test.exs, scenario_tracking_test.exs (the record's `purpose` and
  keys are unchanged; `continues` is added only to a continuation's record), commit_provenance_test.exs and
  build_preconditions_test.exs, and the other ScriptedBuildFixture users (pre_verification_settlement_test.exs,
  review_packet_test.exs, verification_ownership_lifecycle_test.exs, superseded_objection_test.exs), which run with the
  changed fixture unedited (probed at 99f93f60: those files, controller_verification_test.exs, failure_report_test.exs
  and build_reconcile_test.exs, 84 tests, pass with `:route`, `codex-alt` and `:new_session_on_resume` added).

The whole offline suite at 99f93f60 (1384 tests) was run with the decision's inputs logged at the point between the
two breakers: build_breakers_test.exs test 10 is the only existing test whose Build meets a non-empty continuation
set.

No existing test is renamed or removed. `priv/kogen/test-reliability.yaml` binds rows by test name (it has no row for
failure_report_test.exs or build_reconcile_test.exs), so it and `test-reliability-remediation.yaml` stay unedited;
the new tests need no row.

## Non-goals

- A resume flag, waiting inside a Build, cross-machine continuation (rule 49, later).
- Continuing a Build that died during publication, or reconciling before `check_complete_absent/2` (build-reconcile).
- A transcript archive and repro command (session-telemetry-and-event-log). Notification (rule 37).
- A paid target (rule 49). Changing verification.ex, `offline_retries`, `@guard_reworks` or the record's `purpose`.

## Notes for the Developer (Opus review at 99f93f60)

- Test 1 compares the captured report BYTES (read the file before and after), not the decoded map `r1`.
- Test 15's `record_sha256` is P's report's `record_sha256`.
