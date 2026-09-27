# Report Builds whose controller died

Shaped against develop e5988718, where `failure-reports` (e65392cf, `.kogen/intents/complete/failure-reports/`) and
`build-breakers` (e5988718, `.kogen/intents/complete/build-breakers/`) have landed. Part 3 of 4: split at e5988718
from the `build-continuation` Draft, which was too big for one Build (see questions.md, Audit). **Build it before
`build-continuation`** (part 4), which continues the Candidates this part reports.

This package specifies what an admitted Build must write about earlier Builds whose controller died, and what
`mix kogen.candidates` prints. How build.ex, `Kogen.Build.Workspace` and the report module do it is up to the
Developer; `lib/kogen/build/reconcile.ex` is guarded in case the Developer wants a separate module. Function names
below describe the code at e5988718.

## Launch

```sh
mix kogen.build --route codex build-reconcile
```

Every proof is offline (DIRECTION rules 49, 51).

## Why (the code at e5988718)

- A killed controller runs no stop, so it writes no failure report. `Workspace.list/1` shows its owner record, still
  `running` on disk, as `stopped: interrupted` (`effective_status/2`: no live lock with that build id), and
  `mix kogen.candidates` prints `report:   none` for it. The next Build reclaims the stale lock
  (`Kogen.ProcessCustody.acquire/1` prints "Reclaimed a stale build lock; reaped: …") and starts a fresh Candidate.
  Nothing records what the dead Build had spent or where it stopped. Probed at e5988718 with a stand-in killed by
  `kill -9` while its fake Developer hung in the resume after a failed cycle: the dead record is `status: pending`,
  its last attempt has `developer_session_id` `developer-session` and one `cycle_signatures` entry, its
  `state.json` has `offline_failures` 1 and `terminal_state` `pending`, the lock is left behind, and the next Build
  prints "Reclaimed a stale build lock; reaped: no live groups", publishes a new Candidate and leaves the dead
  Build with no report.
- A report holds no verification budget. `record.json` gets `verification_state` and `failure_signatures` only at
  settlement (`settle_verification/3`), which a provider stop or a killed controller after a pending cycle never
  reaches (probed: the provider-stopped attempt's keys are `attempt_token`, `cycle_signatures`,
  `developer_invocation`, `developer_notes`, `developer_session_id`, `failure`, `jev`, `number`, `outer_attempt`,
  `provider`, `status`, `stop_class`, `verification_context`). The only durable copy of the counts is the attempt's
  `state.json`, which `Verification.persist/5` rewrites atomically after every cycle.
- A controller killed during publication leaves the record `status: accepted` (`accept_verdict/6` →
  `Tracking.apply_verdict/4`, then `publish/5` → `accept/6` commits in the Candidate → `publish_to_control/2` →
  `Workspace.fast_forward/2` → `Workspace.remove_published/1`) and the owner record `running`. Whether the admitted
  branch already moved decides what is left. Nothing reports either case, and README.md says "Reports deliberately
  have no continuation, budget, publication or `published` fields."

## Outcome

### Two report fields

Every report failure-reports writes (`Kogen.Build.FailureReport.record_failure/4`, and the reports reconcile writes
below) gains two keys, always present:

- **`budget_state`**: the stopped attempt's verification budget, or null when the record has no attempt (readiness,
  admission) or the attempt has no `state.json` yet. Otherwise it is exactly these keys:
  - `outer_attempt`: the attempt's `number` (0 for the first attempt);
  - `offline_retries` and `verification_retries`: from the attempt's frozen `context.json`;
  - `offline_failures` (0 when `state.json` has no such key, as before a first cycle), `failures_since_pass` and
    `terminal_state`: from the attempt's `state.json` as last persisted;
  - `state`: the control-relative path of that `state.json`,
    `.kogen/runtime/scenario-tracking/<build-id>/verification/attempt-<number>-<attempt_token>/state.json`;
  - `state_sha256`: the lowercase hex sha256 of that file's bytes.

  A stop writes the same map into the stopped attempt in `record.json` (key `budget_state`) before the report, so
  the report's `record_sha256` still binds the record's final bytes. Reconcile never writes the dead record.
- **`published`**: null except on a `publication-interrupted` report, where it is true or false (below).

Settlement, `verification_state`, `failure_signatures`, every digest and every other report field stay as landed.

### Two categories

The one table in `lib/kogen/build/failure_report.ex` gains two rows. Neither counts toward a breaker, so the landed
`Breakers.environment_state/1` skips them and `Breakers.item_refusal/4` ignores them:

| category | class | next_action | next_command | counts_toward |
| --- | --- | --- | --- | --- |
| `interrupted` | `interrupted` | `rebuild` | null | null |
| `publication-interrupted` | `interrupted` | `inspect`; `remove` when `published` is true | `mix kogen.candidates.remove <build id>` when `published` is true, else null | null |

`FailureReport.classify/1` returns `{"interrupted", "rebuild"}` and `{"interrupted", "inspect"}` for them, and
`counts_toward/1` returns nil for both (at e5988718 its `case` has no clause for a class `interrupted`). The
landed rows are unchanged. `build-continuation` later turns `rebuild` into `continue` for a continuable
`interrupted` report.

### Reconcile: the next admitted Build reports a dead one

In `Kogen.Build.run/3`, right after `acquire_lock/1` returns `:ok` and before `admission_breakers/5`, every
`mix kogen.build` (of any slug) reconciles this control's owner records. Holding the lock means every owner record
still `running` on disk is dead: `acquire/1` refuses a live holder and reclaims a dead one, and this Build has not
claimed its own build id yet. So reconcile takes every owner record `Workspace.list/1` shows as
`stopped: interrupted`, reads its tracking directory (`.kogen/runtime/scenario-tracking/<owner build_id>/`), and:

- **No report yet.** It writes one through the landed writer (temp file, no-clobber publish):
  - `category`: `publication-interrupted` when the dead **record's** `status` is `accepted`, otherwise
    `interrupted`. The owner status is never used for this (the superseded package's F4 bug).
  - `reason`: starts `interrupted: ` or `publication-interrupted: `, then says the Build's controller exited without
    a stop, with the record's status.
  - `stop_class` null; `developer_session_id` the last attempt's (null when none was recorded: a Codex thread id
    is recorded only after the turn returns, so a controller killed during the first Developer turn has none);
    `signature` in failure-reports' order (the last attempt's last `failure_signatures` entry, else its last
    `cycle_signatures` entry, else `FailureSignature.for_stop/2` over the category and reason);
    `same_signature_count` as landed; `budget_state` from the last attempt's `context.json` and `state.json`;
    `candidate` from the owner record (`worktree_path`, `branch`, `harness_home`, and the owner record's path);
    `candidate_build_id` and `build_id` the owner's `build_id`; `record` and `record_sha256` from the dead record's
    bytes as they are on disk.
  - `published` for `publication-interrupted` (below).
- **Owner status.** Then it sets the owner status to `stopped: <category>`. If a report already existed (a
  controller killed after its report and before its owner status), the owner status takes that report's category
  and the report is left as it is.

The dead record is never modified, and a report is written once: a later reconcile leaves it byte-identical.
Reconcile writes nothing for an owner record whose tracking directory has no `record.json`. `mix kogen.candidates`
stays read-only. `kill -9`, SIGHUP/SIGTERM (`Mix.Tasks.Kogen.Build.SignalHandler` releases the lock and halts, so the
owner record stays `running`), a crash or a reboot all end up here.

A reconciling Build that is then refused by a breaker has still reconciled. A request refused before the lock (for
example "Complete Intent already exists") reconciles nothing, as today.

### A controller killed during publication

"Published" means what `Workspace.remove/3`'s `reachable/3` already tests: the Candidate branch's tip differs from
the owner's `admitted_commit` and is an ancestor of `refs/heads/<admitted_branch>`.

- **Not published** (killed before the fast-forward). Reconcile writes `publication-interrupted` with `published`
  false and `next_action` `inspect`.
- **Published** (killed after the fast-forward and before `remove_published/1`). Control now holds
  `.kogen/intents/complete/<slug>`, so a rerun of the same slug is rejected by `check_complete_absent/2` with
  "Complete Intent already exists: <slug>" before the lock, as today, and writes nothing. The next admitted Build of
  any other slug reconciles it with `published` true, `next_action` `remove` and `next_command`
  `mix kogen.candidates.remove <build id>`. `mix kogen.candidates.remove <build id>` removes it without
  `--discard-accepted`, as it already does for a reachable commit.

### Visible in `mix kogen.candidates`

For every record shown as `stopped: interrupted` or `stopped: publication-interrupted` whose Candidate is published,
`mix kogen.candidates` adds one line, with or without a report:

```text
  published: <tip> is on <admitted branch>; remove it with mix kogen.candidates.remove <build id>
```

The line is indented by two spaces like every other field of an entry (lib/mix/tasks/kogen.candidates.ex) and is
printed immediately after the entry's `path:` line. Tests match it only as that line: positive checks use
`~r/^  published: <tip> is on <branch>; remove it with mix kogen.candidates.remove <id>$/m`, negative checks use
`refute output =~ ~r/^\s*published: /m` (a plain `=~ "published:"` would also match the existing
`accepted-unpublished` status text). No other record gets the line. Every existing line is unchanged (`report:   none` without a report; `class:`,
`next:` and `report:  <path>` with one).

### Documentation

README.md's "Failure reports" section documents `budget_state`, `published`, the two new rows, reconcile and the
`published:` line, and drops the sentence "Reports deliberately have no continuation, budget, publication or
`published` fields" (it says instead that continuation fields come with build-continuation).

## Tests the Developer writes

`test/kogen/build_reconcile_test.exs` (new; `use Kogen.IsolatedCase, async: true`). Command:
`mix test test/kogen/build_reconcile_test.exs`, and `make check`. Every test uses its own `ScriptedBuildFixture`
control (`Fixture.fixture!()`: codex protocol, session `developer-session`, `offline_retries: 4`,
`verification_retries: 2`, `outer_resumptions: 3`, slug `scripted-build`). Tests that run a stand-in or several
Builds use `@moduletag timeout: 600_000` (as build_breakers_test.exs does); this changes no Build or gate timeout.
Every test that starts a stand-in registers an `on_exit` that kills the stand-in and the fake pid if still alive.

Shared setup and helpers:

- `tail`: the `output` of `test/support/provider_tails/be_n9crq_claude_session_limit.json` (as
  failure_report_test.exs's `fixture_output!/1` reads it).
- `provider_stopped!(dir)`: `Fixture.run(dir, fail_first: [1], provider_fail: ["developer-2"], provider_tail: tail)`
  returns `{:error, message}` containing `category: provider`; P is the one record's build id. (Probed at e5988718:
  cycle 1 fails, the resume of `developer-session` hits the usage limit, the Build stops as `provider`.)
- `killed!(dir, opts)`: `Fixture.start_standin!(dir, opts)`, then `Fixture.await_hanging!(dir)` (the fake's pid),
  then `kill -9` of the stand-in's OS pid, then a bounded wait (20 s) until both the stand-in and the fake pid are
  gone. P is the one record's build id.
- `other!(dir, slug, id)`: `Fixture.add_intent!(dir, slug, id)` then `Fixture.run(dir, slug: slug)`, which returns
  `:ok` (published). This is "the next admitted Build of another slug". The ids are
  `01960000-0000-7000-8000-0000000c0de3` for `scripted-other` and `01960000-0000-7000-8000-0000000c0de4` for
  `scripted-third`.
- `sha(bytes)`: lowercase hex sha256. `report(dir, id)`: the decoded
  `.kogen/runtime/scenario-tracking/<id>/failure-report.json`. `owner(dir, id)`: the decoded owner record file
  `Workspace.owner_path(dir, id)` as it is on disk (not `Workspace.list/1`'s effective status).
- `tree(path)`: a map of every file under the Candidate worktree (except `.git`) to the sha256 of its bytes.

Tests never refute report keys this package doesn't add (build-continuation adds `continuable` and `continues`).

### Budget state

1. **"a provider stop records the attempt's budget_state in the report and the record"**
   - Setup: `provider_stopped!(dir)`.
   - Expected: the report's `budget_state` equals `%{"outer_attempt" => 0, "offline_retries" => 4,
     "verification_retries" => 2, "offline_failures" => 1, "failures_since_pass" => 0, "terminal_state" => "pending",
     "state" => <rel>, "state_sha256" => sha(File.read!(<control>/<rel>))}`, where `<rel>` is
     `.kogen/runtime/scenario-tracking/<P>/verification/attempt-0-<token>/state.json` and `<token>` the record's last
     attempt's `attempt_token`. The record's last attempt has the same map under `budget_state`. The report has
     `published` nil (key present) and its `record_sha256` equals sha(record.json bytes).
2. **"a settled exhaustion records its terminal budget_state and a stop before any attempt records none"**
   - Setup: one fixture run with `fail_all: [1]` (probed: five offline cycles fail, `offline retries exhausted`,
     category `offline-exhausted`); a second fixture with `File.rm_rf!(Path.join(dir2, "deps"))` (an empty
     untracked directory, so control stays clean), run with no options.
   - Expected: the first report's `budget_state` has `offline_failures` 5, `failures_since_pass` 0 and
     `terminal_state` `offline_exhausted`, and equals the record's last attempt's `budget_state`. The second returns
     `{:error, message}` containing `category: admission`, and its report has `budget_state` nil and `published` nil.

### Killed controllers

3. **"a controller killed after a failed cycle is reported interrupted by the next admitted Build"**
   - Setup: `killed!(dir, fail_first: [1], hang: ["developer-2"])`. Precondition: `Workspace.list(dir)` shows P as
     `stopped: interrupted`, P's `failure-report.json` does not exist, `owner(dir, P)["status"] == "running"`. Keep
     P's record bytes `r`, `state.json` bytes `s` and `tree(worktree)`.
   - Command: `capture_io` of `other!(dir, "scripted-other", …)`.
   - Expected: the output contains "Reclaimed a stale build lock". `report(dir, P)` has `build_id` and
     `candidate_build_id` P, `category` `interrupted`, `class` `interrupted`, `counts_toward` nil, `next_action`
     `rebuild`, `next_command` nil, `stop_class` nil, `developer_session_id` `developer-session`, `signature` equal to
     the record's last attempt's only `cycle_signatures` entry, `budget_state` with `outer_attempt` 0,
     `offline_retries` 4, `verification_retries` 2, `offline_failures` 1, `failures_since_pass` 0, `terminal_state`
     `pending` and `state_sha256` sha(`s`), `published` nil, `record_sha256` sha(`r`), `candidate` equal to
     `%{"worktree" => <P's worktree_path>, "branch" => <P's branch>, "harness_home" => <P's harness_home>,
     "owner_record" => Workspace.owner_path(dir, P)}`, a `reason` starting `interrupted: ` and a `stopped_at` with
     microseconds. `owner(dir, P)["status"] == "stopped: interrupted"`. P's record bytes are still `r`, and P's
     worktree `tree` is unchanged.
   - Command: `other!(dir, "scripted-third", …)`.
   - Expected: P's report bytes are unchanged, P's tracking directory holds exactly one file named
     `failure-report.json` and no `.failure-report-*.tmp`.
4. **"a controller killed during its first Developer turn is reported with no session"**
   - Setup: `killed!(dir, hang: ["developer-1"])`.
   - Command: `other!(dir, "scripted-other", …)`.
   - Expected: `report(dir, P)` has `category` `interrupted`, `next_action` `rebuild`, `developer_session_id` nil,
     a `signature` whose `source` is `stop`, and `budget_state` with `offline_failures` 0, `failures_since_pass` 0 and
     `terminal_state` `pending`. `owner(dir, P)["status"] == "stopped: interrupted"`.
5. **"a controller killed after its report and before its owner status gets that report's category"**
   - Setup: `provider_stopped!(dir)`; keep the report bytes; rewrite P's owner record file with `status` `running`.
   - Command: `other!(dir, "scripted-other", …)`.
   - Expected: `owner(dir, P)["status"] == "stopped: provider"`, P's report bytes are unchanged, and P's tracking
     directory holds one report.

### Publication crashes

6. **"a controller killed before the fast-forward is publication-interrupted and not published"**
   - Setup: `provider_stopped!(dir)`; `File.rm!` P's report; rewrite P's `record.json` with `status` `accepted`
     (keep its bytes `r`); rewrite P's owner record with `status` `running`. P's Candidate tip is still
     `admitted_commit`.
   - Command: `other!(dir, "scripted-other", …)`, then `mix kogen.candidates` (`capture_io`, cwd `dir`).
   - Expected: `report(dir, P)` has `category` `publication-interrupted`, `class` `interrupted`, `published` false,
     `next_action` `inspect`, `next_command` nil, `counts_toward` nil, a `reason` starting
     `publication-interrupted: ` and `record_sha256` sha(`r`). `owner(dir, P)["status"] ==
     "stopped: publication-interrupted"`. The command output contains no `published:` line.
7. **"a controller killed after the fast-forward is rejected for its own slug, shown as published, reconciled by
   another slug and removable"**
   - Setup: as test 6, then in P's worktree write `.kogen/intents/complete/scripted-build/INTENT.md`
     (`"# fabricated\n"`) and commit it with the fixture's Git author environment (tip `t`), and run
     `git merge --ff-only t` in control. Control is clean.
   - Command 1: `Fixture.run(dir)`.
   - Expected 1: `{:error, "Complete Intent already exists: scripted-build"}`; no `.kogen/build.lock`, still one
     `record.json`, no report for P, `owner(dir, P)["status"] == "running"`.
   - Command 2: `mix kogen.candidates`.
   - Expected 2: P's entry shows `stopped: interrupted`, the line `published: <t> is on main; remove it with mix
     kogen.candidates.remove <P>` and `report:   none`.
   - Command 3: `other!(dir, "scripted-other", …)`, then `mix kogen.candidates`.
   - Expected 3: `report(dir, P)` has `category` `publication-interrupted`, `published` true, `next_action`
     `remove`, `next_command` `mix kogen.candidates.remove <P>` and `counts_toward` nil;
     `owner(dir, P)["status"] == "stopped: publication-interrupted"`; the output still has the `published:` line and
     now `class:   interrupted` and `next:    remove (mix kogen.candidates.remove <P>)`.
   - Command 4: `Mix.Tasks.Kogen.Candidates.Remove.run([P])` (cwd `dir`).
   - Expected 4: it succeeds without `--discard-accepted`; P's worktree, branch and owner record are gone.

### Table

8. **"interrupted and publication-interrupted are class interrupted and count toward nothing"**
   - `FailureReport.classify("interrupted") == {"interrupted", "rebuild"}`,
     `FailureReport.classify("publication-interrupted") == {"interrupted", "inspect"}`, and `counts_toward/1` is nil
     for both. Every landed row still classifies as failure_report_test.exs asserts.

`test/kogen/candidates_command_test.exs`, with that file's own helpers (`new_worktree/4`, `commit_in_worktree/2`,
`write_owner!/3`, `git!/3`) in project P and no lock for these build ids:

9. **"a dead running or publication-interrupted Candidate whose commit is on its admitted branch prints the published
   line"**
   - Setup: Candidate `p5pub` (commit `c5` fast-forwarded onto `main` in control, owner `running`) and `p6pub`
     (commit `c6`, created from `c5` and fast-forwarded onto `main`, owner `stopped: publication-interrupted`).
   - Expected: `mix kogen.candidates` prints `published: <c5> is on main; remove it with mix kogen.candidates.remove
     p5pub` and the same line for `p6pub` and `<c6>`; `Workspace.remove(p.control, "p5pub")` returns `{:ok, _}`
     without `discard_accepted`.
10. **"a Candidate whose commit is not on its admitted branch prints no published line"**
    - Setup: Candidate `p7unpub` with a commit that is not merged, owner `running`.
    - Expected: `mix kogen.candidates` shows `p7unpub` as `stopped: interrupted` and its output contains no
      `published:` line (`refute output =~ ~r/^\s*published: /m`); `Workspace.remove(p.control, "p7unpub")` still refuses without `discard_accepted` ("not
      reachable").

## Existing tests and fixtures

Fixtures that change:

- **`test/support/scripted_build_fixture.ex`**:
  - `run/2` adds `{"KOGEN_ROLE", nil}` and `{"KOGEN_HARNESS_HOME", nil}` to the environment it sets (and restores).
    A Developer running these tests inside its own Build session inherits both; every fixture Build clears them.
  - `run/2` gains `:slug` (default `scripted-build`, passed to `Kogen.Build.run/3`) and `:hang`: a list of
    `developer-<n>` labels, like `:provider_fail`; the listed invocation writes its own pid into
    `<harness home>/fake-state/developer-hanging` and sleeps until killed, before printing anything (so a hang on
    `developer-1` leaves no session id). The pid is written to a temporary file in the same directory and renamed to
    `developer-hanging`, so the file never exists without its pid.
  - `add_intent!(dir, slug, id)` writes an Approved package for `slug` with that id, the fixture's scenarios and
    risks (ignored by Git, so control stays clean).
  - `records!(dir)`: every `{build_id, path, decoded record}` under `.kogen/runtime/scenario-tracking/`, oldest
    first. `record_path!/1` still asserts a single record.
  - `start_standin!(dir, opts)` starts `test/support/scripted_controller_standin.exs` in a separate OS process and
    returns its port and OS pid; `await_hanging!(dir)` waits (bounded, 60 s) for a `developer-hanging` file under
    this control's harness homes whose content parses as a positive integer, and returns that pid.
  - Existing callers pass none of the new options and see today's behaviour.
- **`test/support/scripted_controller_standin.exs`** (new) runs `Kogen.ScriptedBuildFixture.run/2` for a fixture
  dir and options given as arguments (options JSON-encoded), in its own OS process. It loads the fixture with
  `Code.require_file`, as test_helper.exs loads support files. It is started as `elixir` with `-pa` for every
  absolute path of the test VM's `:code.get_path()` (as `Kogen.IsolatedCase`'s `child_args/3` does), never as
  `mix run`: inside an IsolatedCase child `MIX_BUILD_PATH` names an empty private `_build`, so `mix run` would
  compile the whole project first (probed at e5988718: in a copy it failed compiling `yamerl`; the `elixir -pa`
  form ran the Build within seconds). Its environment unsets `KOGEN_ROLE` and `KOGEN_HARNESS_HOME`
  (`{~c"KOGEN_ROLE", false}`, `{~c"KOGEN_HARNESS_HOME", false}` in `Port.open/2`). Tests synchronise on the fake's
  `developer-hanging` file, never on stand-in output.

Existing tests that change:

- **`test/kogen/failure_report_test.exs`**: in the private helper `assert_report!/4`, `refute Map.has_key?(report,
  "budget_state")` and `refute Map.has_key?(report, "published")` become `assert Map.has_key?(…)`. Its
  `refute Map.has_key?(report, "continues")` and `"continuable"` lines, every other line and every test name stay
  as they are. The tests that call it ("two offline exhaustion Builds write final reports and count the same
  signature", "Jev cannot-comply, missing deps, and publication refusal each write their terminal report", "a Claude
  login rejection is an environment stop with one Developer invocation", "usage-limited Developer stop keeps the
  provider class and session") keep their names and pass.

These pass unedited (existing-expectations-kept):

- failure_report_test.exs "category table keeps the approved classes and excludes continuation rows" and "the
  category table is exhaustive and exposes counting semantics": `classify("interrupted")` is
  `{"interrupted", "rebuild"}`, not the refuted `{"interrupted", "continue"}`, and no landed row changes.
- build_breakers_test.exs, whole (no test leaves a `running` owner record, so reconcile writes nothing there).
- build_workspace_test.exs "a Build stopped by #{category} keeps its Candidate, names it and is never reused by the
  next Build" (every stop sets its owner status, so its second Build reconciles nothing and gets a fresh Candidate),
  "the owner record status is running before any provider launch and stopped afterwards" and "refused cleanup after
  the fast-forward is published-retained and removable without the flag".
- candidates_command_test.exs's existing tests: its fixed scenario's `stopped: interrupted` record `p4` has no
  commit, so no `published:` line appears; its `refute Regex.match?(~r/^published:/m, output)` is tightened to
  `refute output =~ ~r/^\s*published: /m` (the line is indented) and holds; every other
  line is unchanged.
- commit_provenance_test.exs "first and subsequent Builds record truthful automated provenance" (its exact
  `{:error, "Complete Intent already exists: intent-one"}` still comes before the lock),
  scenario_tracking_test.exs (the record's `purpose` string and keys are unchanged), process_custody_test.exs
  (the custody stand-in is unchanged), controller_verification_test.exs and build_preconditions_test.exs.

No existing test is renamed or removed. `priv/kogen/test-reliability.yaml` binds rows by test name, so it and
`test-reliability-remediation.yaml` stay unedited; the new tests need no row.

## Non-goals

- Continuing a Candidate, the continuation refusals, `continuable`, `continues`, `session-lost`, the owner
  record's `tracking_build_id`: build-continuation.
- Reconciling before `check_complete_absent/2`, or in `mix kogen.candidates` (it stays read-only).
- Changing settlement, `verification_state`, verification.ex, the record's `purpose`, or any landed category.
- A transcript archive and repro command (session-telemetry-and-event-log). Notification (rule 37). A paid target.

## Notes for the Developer (Opus review, 2026-09-27)

- tests 9 and 10 build their own records (not the shared candidates fixture), so the existing `accepted-unpublished`
  status text is not in their output.
- `records!/1` sorts by the record's `created_at` (then build id).
- When reconcile rewrites an owner status, rebuild the candidate map from the owner record and keep its
  `candidate_commit`.
- The README may only name files and `Module.fun/arity` that exist (readme_guidance_test.exs).
