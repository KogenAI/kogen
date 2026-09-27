# Refuse Builds that keep failing the same way

Shaped against develop e65392cf, where part 1 (`failure-reports`, `.kogen/intents/complete/failure-reports/`) has
landed. Part 2 of 3, split from the approved `durable-builds-and-failure-reports` (see questions.md, Audit). This
package reads the failure reports part 1 writes, exactly as they landed. It adds no report field.

This package specifies what admission must refuse, admit, write and print. How build.ex is structured to do that is
up to the Developer. There is no Candidate starting point: no saved diff holds breaker code (references.yaml).

## Launch

```sh
mix kogen.build --route codex build-breakers
```

Every proof is offline (DIRECTION rule 51).

## Why

Rule 49: a Build that failed the same way twice on an unchanged package is not rebuilt a third time; it goes back to
shaping (`reshape_details`). Three environment stops in a row across Intents stop admissions until a readiness check
passes or a Build succeeds. Since failure-reports, every stopped Build leaves
`.kogen/runtime/scenario-tracking/<build-id>/failure-report.json`, and the second same-signature report already says
`next_action: reshape_details`. But nothing reads the reports, so the same failure is rebuilt again and again, and a
logged-out harness burns one Build per Intent. A fresh Build also starts with no idea what the previous Build of the
same package failed on (lesson 25).

## What the reports hold (landed at e65392cf)

`Kogen.Build.FailureReport` (lib/kogen/build/failure_report.ex) writes one report per Build that stopped after its
tracking record existed, at `FailureReport.report_path(control, build_id)`, which is
`<control>/.kogen/runtime/scenario-tracking/<build-id>/failure-report.json` (absolute). The fields this package reads:

- `intent_id`, `approved_package_digest` (the tracking record's; computed by the private `approved_digest/1` in
  lib/kogen/build/tracking.ex as the lowercase hex sha256 of `:erlang.term_to_binary/1` of the Approved entries
  `Kogen.Build.run/3` reads), `build_id`;
- `stopped_at`: `DateTime.utc_now() |> DateTime.to_iso8601()`, microseconds, for example
  `2026-09-27T14:17:52.623567Z`;
- `category`, `class` (`item`, `shaping`, `environment` or `provider`) and `counts_toward` from the one table in
  `FailureReport.classify/1` and `counts_toward/1`:
  - `item` for `class` `item` and `shaping` (categories `verification-exhausted`, `offline-exhausted`,
    `unchanged-candidate`, `outer-allowance-exhausted`, `guard-violation`, `protected-path`, `git-policy`,
    `integrity`, `review-failure`, `cannot-comply`);
  - `environment` for `environment` (a harness readiness failure or a login rejection), `provider-failure`,
    `write-boundary`, `admission`, `publication-failed` and `accepted-unpublished`;
  - JSON `null` for `provider`;
- `signature`: a map with `digest`, `target`, `first_failure`, `error_head`, `source` and, for target failures,
  `reproduce` (often null). `source` is `frame` or `tail` for a failed target, and `stop` for a stop signature
  (`FailureSignature.for_stop/2`, digest over category and reason; its `target` and `first_failure` are the category);
- `next_action` and `next_command`. A readiness stop has `next_command` `mix kogen.claude.login` (probed at e65392cf).

`same_signature_count` is written once, when the report is written. It counts reports with the same `intent_id`,
package digest and signature digest whatever their `counts_toward` (the third of three readiness stops of one Intent
has 3). The breakers do not read it; they recount the reports on disk (Assumed 3).

## Outcome

### Where the checks run

Both checks run in `Kogen.Build.run/3` after the build lock is held (`acquire_lock/1`) and before `Tracking.new/5`.
That is failure-reports' pre-admission boundary, so a refusal is like today's refusals there (unknown route,
`check_complete_absent/2`, a live lock): no tracking record, no report, no Candidate, no owner record, no harness
home, no Developer launch. A refusal never counts toward a breaker.

1. The environment breaker runs first.
2. The item breaker runs second.

build-continuation later adds reconcile before step 1 and the continuation decision between the two, so keep them as
two separate steps. Until then every Build is fresh.

The current package digest is computed from the Approved entries `run/3` already read, the same way
`Tracking.approved_digest/1` computes the record's (make it public, or share one function; never a second hash).

### Item breaker

A Build is refused when two or more of this control's reports all have:

- `counts_toward` `item`;
- `intent_id` equal to the Approved Intent's id;
- `approved_package_digest` equal to the current package digest;
- the same `signature.digest` as each other.

Reports are read from `<control>/.kogen/runtime/scenario-tracking/*/failure-report.json`. A report that does not
decode is skipped. If several digests each have two or more matching reports, the refusal names the group holding the
latest `stopped_at`.

The refusal is `{:error, message}` where the message is exactly:

```text
Build refused (item breaker): <slug> stopped <n> times with the same failure signature on this Approved package; next action: <action>; first failure: <first_failure>; signature: <digest>; failure reports: <path>, <path>
```

- `<action>` is `reshape_scope` if any matching report has `class` `shaping`, otherwise `reshape_details`.
- `<first_failure>` and `<digest>` are the matching reports' `signature.first_failure` and `signature.digest`.
- The paths are every matching report's absolute path, oldest `stopped_at` first.

Editing the Approved package changes its digest, so the package is admitted again. Another Intent is never refused by
this Intent's reports. Deleting a report file changes the count at once: the state is the files on disk.

### Environment breaker

The breaker looks at the *environment run*:

- **Which reports.** All of this control's reports, across Intents, ordered by `stopped_at` parsed as a DateTime
  (ties by `build_id`). Only reports whose `stopped_at` is later than the latest `cleared_at` of any
  `<control>/.kogen/runtime/scenario-tracking/*/environment-clear.json` count.
- **The run.** The trailing sequence of reports with `counts_toward` `environment`. A report with `counts_toward`
  `item` ends it. Reports with `counts_toward` null (`provider`, and later build-continuation's interrupted
  categories) are skipped.
- **Tripped.** The run has three or more reports.

When not tripped, admission runs no extra probe. When tripped, admission runs the harness readiness itself:
`Kogen.Harness.open_roles(config, [:developer, :reviewer, :expert], control)` for the Build's resolved route, with
no launch, then `Kogen.Harness.close/1` on success. With no launch, the Claude adapter runs `<executable> auth status`
in the controller's working directory with the scope's own environment (probed at e65392cf), so fake_claude logs
the call to `<cwd>/.kogen/runtime/fake-harness-log`. The Build's own readiness later runs in the Candidate and
logs to the harness home, never to the cwd. With `KOGEN_HARNESS` set, the Codex adapter runs no command, so fixture
proofs use the Claude route.

- **Readiness fails.** The Build is refused. The message is exactly:

  ```text
  Build refused (environment breaker): <n> environment stops in a row; readiness: <readiness error>; failure reports: <path> (<next_command>), <path> (<next_command>), <path> (<next_command>)
  ```

  Paths are the run's report paths, oldest first. ` (<next_command>)` is left out for a report whose
  `next_command` is null.
- **Readiness passes.** The Build is admitted. Right after `Tracking.new/5` it writes `environment-clear.json` into
  its own tracking directory (the directory of `record.json`):

  ```json
  {"schema_version": 1, "cleared_at": "<UTC ISO 8601, microseconds>", "reason": "readiness", "reports": ["<path>", ...]}
  ```

  `reports` lists the run's report paths, oldest first.

A Build that publishes (`Workspace.fast_forward/2` returned `:ok` in `publish_to_control/2`) writes the same file
with `reason: "published"` when the environment run, computed at that moment, is non-empty. A Build writes at most one
clear file: after a readiness clear its own run is empty.

Local readiness can't see a revoked token (risk `readiness-blind-to-revocation`). A cleared breaker can trip again
after three more first-turn login rejections.

### A fresh Build's first prompt names the last failure

When a Build starts and this control holds a report with `counts_toward` `item`, the Intent's `intent_id`, the
current package digest and a `signature.source` other than `stop`, the first Developer prompt (the prompt of the
fresh launch, which fake_codex saves as `<harness home>/fake-state/developer-launch-prompt`) carries the latest such
report's block:

```text
## First failure

- Target: <signature.target>
- First failure: <signature.first_failure>
- Error head: <signature.error_head>
- Reproduce: <signature.reproduce, or the generic line>

Passes in isolation is not acceptable: reproduce the failure under the gate's concurrency and make it deterministic; an unchanged Candidate stops the Build.
Previous failure report: <absolute report path>
```

Everything from `## First failure` through the "Passes in isolation…" sentence is byte-identical to what
`Kogen.Build.FailureHandoff.render/1` puts in the rework prompt for the same signature. One renderer produces both
(rule 44); the generic `Reproduce:` line is failure-reports' "run the command that `make <target>` runs, whole and at
its normal concurrency, not the one test alone; the controller runs `make <target>` itself after your turn". The
rework prompt's bytes don't change. A stop signature (`source: "stop"`, for example a `cannot-comply` stop) names
no target to reproduce, so it adds no block. With no such report the first prompt is today's prompt.

So the second try knows what the first failed on, and a third is refused by the item breaker.

README.md's "Failure reports" section gains a "Breakers" part: both breakers, their refusal prefixes, how each
clears (edit the package; readiness passes or a Build publishes; `environment-clear.json`), and the first-prompt
block.

## Files

| File | New expectation |
| --- | --- |
| lib/kogen/build.ex | `run/3` runs the two checks between `acquire_lock/1` and `Tracking.new/5`; the readiness clear file is written after `Tracking.new/5`; `publish_to_control/2` writes the published clear file; `developer_prompt(ctx, nil)` adds the block. Every other message, category and prompt is unchanged. |
| lib/kogen/build/tracking.ex | The package digest function is shared (public), with the same bytes. |
| lib/kogen/build/failure_report.ex | May gain report-reading helpers. The category table, fields and `same_signature_count` stay as landed. |
| lib/kogen/build/failure_handoff.ex | The `## First failure` block is rendered by one function both prompts call; `render/1`'s output is unchanged. |
| lib/kogen/build/breakers.ex | Optional new module for the checks. |
| README.md | The "Breakers" part above. |
| test/kogen/build_breakers_test.exs | New; the tests below. |

## Tests the Developer writes

`test/kogen/build_breakers_test.exs` (new; `use Kogen.IsolatedCase, async: true`). Command:
`mix test test/kogen/build_breakers_test.exs`, and `make check`. Every test uses its own fresh control from
`Kogen.WorkspaceFixture.create!/1` (risk `breaker-in-fixtures`) and runs Builds with `Workspace.build!/2`.

Shared setup and helpers:

- `reports(control)`: decoded reports under `scenario-tracking/*/failure-report.json`, each with its path, sorted by
  `stopped_at`.
- `fail_always`: `harness: Workspace.support("fake_codex"), env: [{"FAKE_CHECK_FAIL_ALWAYS", "1"}]`. Each such Build
  returns `{:error, message}` with `category: offline-exhausted` and writes a report whose signature has
  `source` `tail`, `target` `check`, and the same digest in every Build of one control (probed at e65392cf).
- `admission_counts(control)`: the number of `scenario-tracking/*` directories, of `Workspace.owner_records/1`, and of
  `git worktree list --porcelain` entries.
- `sentinel!`: `Workspace.fake!(dir, "sentinel", "#!/bin/sh\ntouch #{marker}\nexit 1\n")`, a harness that marks any
  launch.
- Claude route: `Workspace.create!(route: :claude)`, `KOGEN_CLAUDE_ROOT` set to one `Workspace.claude_root!()` per
  test, `harness: Workspace.support("fake_claude")`, every Build given its own `cwd: Workspace.tmp_dir!("cwd")`, and
  `{"KOGEN_HARNESS_HOME", nil}` in every Build's `env:` (a Developer running these tests inside its own Build turn inherits
  `KOGEN_HARNESS_HOME`, and `test/support/fake_claude` would then log to `$KOGEN_HARNESS_HOME/fake-state` instead of the
  cwd, making `probe_lines/1` return `[]`; the controller's gate has no such variable).
  `logged_out` adds `{"FAKE_CLAUDE_LOGGED_OUT", "1"}`. Such a Build returns `{:error, message}` containing
  `category: environment` and `next action: environment (mix kogen.claude.login)`. `probe_lines(cwd)` is the list of
  lines of `<cwd>/.kogen/runtime/fake-harness-log` starting `argv:` (`[]` when the file is absent).
- A second Intent: `Workspace.write_intent!(control, "second-intent", intent_id: "01a0c467-0000-7000-8000-00000000b2e2")`
  (ignored by Git, so control stays clean), built with `slug: "second-intent"`.

### Item breaker

1. **"a third Build of a package that stopped twice with the same signature is refused before admission"**
   - Setup: two `fail_always` Builds. Precondition: two reports, same `signature.digest`, the second with
     `same_signature_count` 2 and `next_action` `reshape_details`. Record `admission_counts` and
     `Workspace.control_state/1`.
   - Command: a third Build with the sentinel harness and `FAKE_CHECK_FAIL_ALWAYS=1`.
   - Expected: `{:error, message}` where `message` equals the item-breaker format with `<slug>` `workspace-fixture`,
     `<n>` 2, `reshape_details`, `first failure: check`, the shared digest and both report paths in order.
     `admission_counts` and `control_state` are unchanged, there are still two reports, and the sentinel marker does
     not exist.
2. **"the item breaker counts the reports on disk"**
   - Setup: two `fail_always` Builds; `File.rm!` the first report.
   - Command: a `fail_always` Build, then another.
   - Expected: the first is admitted (its message contains `category: offline-exhausted` and doesn't start with
     `Build refused`) and writes a report with `same_signature_count` 2. The second is refused with the item-breaker
     message naming the remaining old report and the new one.
3. **"an edited Approved package is admitted again"**
   - Setup: two `fail_always` Builds; append `"# edited\n"` to `.kogen/intents/approved/workspace-fixture/intent.yaml`.
     Precondition: `control_state(control).status == ""`.
   - Command: a `fail_always` Build.
   - Expected: admitted; its report's `approved_package_digest` differs from the first two, with `same_signature_count`
     1 and `next_action` `rebuild`.
4. **"another Intent's repeated failures never refuse a Build"**
   - Setup: two `fail_always` Builds of `workspace-fixture`; write the second Intent.
   - Command: a `fail_always` Build with `slug: "second-intent"`.
   - Expected: admitted; its report has `intent_id` `01a0c467-0000-7000-8000-00000000b2e2`, the same signature digest
     as the first two, and `same_signature_count` 1.
5. **"two shaping reports with one signature refuse with reshape_scope"**
   - Setup: one `fail_always` Build (report `r`). Write two reports by hand, at `scenario-tracking/shaping-a/` and
     `shaping-b/failure-report.json`, with `r`'s `intent_id` and `approved_package_digest`, `category`
     `cannot-comply`, `class` `shaping`, `counts_toward` `item`, `next_action` `reshape_scope`, `stopped_at` now, and
     `signature` `%{"digest" => "hand-shaping", "target" => "cannot-comply", "first_failure" => "cannot-comply",
     "source" => "stop"}`.
   - Command: a Build with the sentinel harness.
   - Expected: the item-breaker message with `next action: reshape_scope`, `first failure: cannot-comply`,
     `signature: hand-shaping` and exactly the two hand-written paths (not `r`'s). The sentinel marker does not exist.
6. **"reports that differ in signature or count toward the environment never trip the item breaker"**
   - Setup: one `fail_always` Build (report `r`). Write four reports by hand with `r`'s `intent_id` and package
     digest: two with `counts_toward` `item`, `category` `offline-exhausted` and `first_failure` `check`, but digests
     `other-1` and `other-2`; two with `counts_toward` `environment`, `category` `environment` and the same digest
     `env-same`. Give them `stopped_at` values in that order, all later than `r`'s.
   - Command: a `fail_always` Build.
   - Expected: admitted (`category: offline-exhausted`; the environment run is two, so no probe is involved).

### Environment breaker

7. **"three environment stops in a row refuse Builds until readiness passes"**
   - Setup (Claude route, second Intent written):
     - Builds 1-3, `logged_out`, slugs `workspace-fixture`, `second-intent`, `workspace-fixture`. Each stops as
       `environment` and each `probe_lines` is `[]`.
   - Build 4, `logged_out`: `{:error, message}` equal to the environment-breaker format with `<n>` 3, a readiness
     error that contains `harness claude is not ready:` and `Run mix kogen.claude.login`, and the three report paths
     in order, each followed by ` (mix kogen.claude.login)`. `probe_lines(cwd4) == ["argv: auth status"]`.
     `admission_counts` is unchanged and there are still three reports.
   - Build 5, with `FAKE_CLAUDE_LOGGED_OUT=0` and `FAKE_CLAUDE_FAIL_TAIL` set to a file holding the `output` of
     `test/support/provider_tails/xfjcrm76_claude_oauth_revoked.json` (a revoked token that passes readiness):
     - it is admitted: `probe_lines(cwd5) == ["argv: auth status"]`;
     - it stops with a message starting `developer: claude login rejected (401) (class environment)`;
     - its tracking directory holds `environment-clear.json` with `schema_version` 1, `reason` `readiness`, `reports`
       equal to Builds 1-3's report paths, and `cleared_at` (µs) later than Build 3's `stopped_at` and earlier than
       Build 5's.
   - Builds 6 and 7, `logged_out`: each is admitted with `probe_lines` `[]` and stops as `environment`.
   - Build 8, `logged_out`: refused with the environment-breaker message naming exactly Builds 5, 6 and 7's reports,
     none of Builds 1-3's.
8. **"an item stop ends the environment run"**
   - Setup (Claude route):
     - Builds 1-2, `logged_out`.
     - Build 3 with `FAKE_CLAUDE_LOGGED_OUT=0` and `FAKE_CHECK_FAIL_ALWAYS=1`, which stops as `offline-exhausted`.
     - Builds 4-5, `logged_out`.
   - Command: Build 6, `logged_out`.
   - Expected: admitted, stops as `environment`, `probe_lines(cwd6) == []`, and no
     `scenario-tracking/*/environment-clear.json` exists.
9. **"a published Build clears the environment run"**
   - Setup (Claude route, second Intent written):
     - Builds 1-2, `logged_out`, `workspace-fixture`.
     - Build 3, `slug: "second-intent"`, logged in, returns `:ok` (published).
   - Expected after Build 3: the newest tracking directory (the one whose `record.json` names `second-intent`) holds
     `environment-clear.json` with `reason` `published` and `reports` equal to Builds 1-2's paths.
   - Command: Builds 4, 5 and 6, `logged_out`, `workspace-fixture`.
   - Expected: all three are admitted with `probe_lines` `[]` and stop as `environment`. Without the clear, Build 6
     would see a run of four.
10. **"a provider stop is skipped, so the run continues across it"**
    - Setup (Claude route):
      - Builds 1-2, `logged_out`.
      - Build 3 with `FAKE_CLAUDE_FAIL_TAIL` set to the `output` of
        `test/support/provider_tails/be_n9crq_claude_session_limit.json`. It stops with category `provider` and
        `counts_toward` null (probed at e65392cf).
      - Build 4, `logged_out`.
    - Command: Build 5, `logged_out`.
    - Expected: refused with the environment-breaker message naming Builds 1, 2 and 4's reports and not Build 3's.
      `probe_lines(cwd5) == ["argv: auth status"]`.
11. **"a published Build with no environment run writes no clear file"**
    - Setup: Claude route.
    - Command: one logged-in Build.
    - Expected: it returns `:ok`, with no `scenario-tracking/*/environment-clear.json` and `probe_lines` `[]`.

### First prompt

12. **"a fresh Build's first prompt names the previous failure of this package"**
    - Setup: one `fail_always` Build (report `r1`, harness home `h1 = r1["candidate"]["harness_home"]`).
    - Command: a second `fail_always` Build (report `r2`, harness home `h2`).
    - Expected:
      - `h1/fake-state/developer-launch-prompt` contains no `## First failure`.
      - `h2/fake-state/developer-launch-prompt` contains the block built from `r1["signature"]`'s `target`,
        `first_failure` and `error_head`, the generic `Reproduce:` line for `make check` (`r1`'s `reproduce` is
        null), the exact "Passes in isolation…" sentence, and `Previous failure report: <r1 path>`.
      - The text from `## First failure` through that sentence equals the first such span in
        `h1/fake-state/verification-resume-prompts` (Build 1's rework prompts, appended by fake_codex).
13. **"a control with no report renders the first prompt without a failure block"**
    - Setup: none.
    - Command: one `fail_always` Build.
    - Expected: its `developer-launch-prompt` contains neither `## First failure` nor `Previous failure report:`.
14. **"another Intent's or an older package's report adds no block"**
    - Setup: one `fail_always` Build of `workspace-fixture`; write the second Intent.
    - Command: a `fail_always` Build of `second-intent`. Then append `"# edited\n"` to `workspace-fixture`'s
      intent.yaml and run a `fail_always` Build of `workspace-fixture`.
    - Expected: neither Build's `developer-launch-prompt` contains `## First failure`.
15. **"a stop-signature report adds no block"**
    - Setup: one Build with `harness: Workspace.support("fake_codex_simple_accept")` and `FAKE_JEV_ANSWERS`
      `{"objection:scenario:fixture-scenario":["objection",0.99]}`. It stops as `cannot-comply` with a stop signature.
    - Command: a `fail_always` Build.
    - Expected: its `developer-launch-prompt` contains no `## First failure`.

## Existing tests and fixtures

No fixture changes. No existing test must change: at e65392cf no test drives two matching item reports or three
environment-counting reports into one control, none reads a later Build's first prompt, and no refusal path they
exercise moves. These pass unedited (existing-expectations-kept):

- build_workspace_test.exs: "a Build stopped by #{category} keeps its Candidate, names it and is never reused by the
  next Build" (two Builds per control; the second is admitted and its first prompt gains a block, which it doesn't
  read), "a Build run from a third directory works in the Candidate and never in that directory or control" (its third
  cwd stays `["third-sentinel.txt"]`: an untripped admission runs no probe), and "Drafts, other packages, approvals and
  the shared login used in control mid-Build never reach the Build, which is accepted and published".
- failure_report_test.exs, whole: "two offline exhaustion Builds write final reports and count the same signature"
  (two Builds; `same_signature_count` 1 then 2), "Jev cannot-comply, missing deps, and publication refusal each write
  their terminal report" (its `assert_report!` counts files named `*failure-report*`, which `environment-clear.json`
  is not), and "a pre-admission route refusal writes neither a record nor a report".
- build_preconditions_test.exs, including the ledger rows "precondition failures never launch the harness" and "a
  missing Jev Keychain item fails before any launch, tracking record or verification context"; its refutations of
  `<control>/.kogen/runtime/fake-harness-log` hold because no probe runs untripped.
- scenario_lifecycle_test.exs "exhaustion preserves unique records without raw logs and publication copies closure
  evidence" (two `record.json`) and "a second Build after a stop gets a new Candidate and leaves the first retained".
- commit_provenance_test.exs "first and subsequent Builds record truthful automated provenance" (its exact
  `{:error, "Complete Intent already exists: intent-one"}` still comes before the lock) and
  commit_failure_rollback_test.exs "restores the Approved Intent and leaves a clean worktree when git commit fails" (a
  `publication-failed` stop, then a published Build, which writes a `published` clear file; `runtime_tracking_records`
  only globs `*/record.json`, so it passes unedited).
- write_boundary_test.exs: the hybrid setup of "role-write-boundary: a hybrid Build's fake roles" (provider-failure,
  then published: `provider-failure` counts toward `environment`, so the publishing Build writes an
  `environment-clear.json` with `reason: published`; no existing assertion lists tracking directories or reads that file,
  so the test passes unedited; there is no probe) and "the harness home's raw log is
  copied into the controller's KOGEN_RAW_LOG_DIR at exit, on success and on a stop".
- core_integrity_test.exs and harness_contract_test.exs (their `fake-harness-log` refutations and `auth status`
  exclusions); controller_handoff_test.exs, two_outer_resumptions_test.exs and candidate_verification_test.exs (the
  first Developer prompt is unchanged with no report).

No existing test is renamed or removed. `priv/kogen/test-reliability.yaml` binds rows by test name, so it and
`test-reliability-remediation.yaml` stay unedited; the new tests need no row.

## Non-goals

- Continuation and reconcile (build-continuation). Any change to the report format or table (failure-reports).
- A counter file, a manual reset command, notification (rule 37).
- Detecting a revoked token at readiness. A paid target.

## Notes for the Developer (Opus re-preflight review, 2026-09-27)

- Test 5: give the two hand-written item reports distinct `stopped_at` values (items have no tie-break).
- Test 6: give the hand-written `other-1`/`other-2` reports `signature.source` `tail` and `target` `check`.
- Tests that run several full Builds (2, 3, 4, 7, 9, 14) may set `@tag timeout:` above IsolatedCase's 120 s default; this
  changes no Build or gate timeout.
