# Questions and choices

No open questions. Decisions: DIRECTION rules 43, 44, 49, 51; lessons 24, 25, 27. Numbers in brackets are the original
package's Assumed items.

## Assumed

1. Reports are the only store of counts; there is no counter file. The environment breaker's reset is an
   `environment-clear.json` in the clearing Build's own tracking directory. [1]
   Reason: rule 49 counts "on an unchanged package" and "across Intents"; the reports already carry both keys, and
   files on disk survive a restart. A reset is an event, not a count.
   Undo: add a per-project counter file and drop the scan.
2. When the environment breaker is tripped, admission runs Kogen's own harness readiness from control (no launch). A
   pass clears the breaker; a failure refuses. [7]
   Reason: rule 49 says "until a readiness check passes or a Build succeeds"; this gives the breaker a reachable way
   to clear with no new command (original round 1, Sol, Opus). Its blind spot for revoked tokens is accepted (risk
   `readiness-blind-to-revocation`).
   Undo: require a published Build to clear it.
3. The item breaker's key is (`intent_id`, current `approved_package_digest`, `signature.digest`) over reports with
   `counts_toward` `item`, recounted from the files on disk at each admission; the stored `same_signature_count` is
   not read. `shaping` reports count too (their `counts_toward` is `item`) and turn the next action into
   `reshape_scope`. [from INTENT; re-derived at e65392cf]
   Reason: rule 49 ("same failure signature twice on an unchanged package → refuse rebuild with reshape_details");
   editing the package is how the Shaper (or automatic reshaping, rule 43) answers it. The landed
   `same_signature_count` is frozen at write time and ignores `counts_toward` (the third readiness stop of one Intent
   has 3), so it can neither drop when a report is removed nor tell item from environment.
   Undo: key on the slug instead of the digest, so only a new package id readmits.
4. Breaker refusals happen after the build lock and before `Tracking.new/5`, like the other pre-admission refusals:
   no record, no report, no count. [6, applied]
   Reason: a refusal spends nothing; counting it would make a tripped breaker trip itself forever. failure-reports
   already defines "before `Tracking.new/5`" as the no-report boundary.
   Undo: write refusal reports into a separate directory.
5. The environment run is every report with `counts_toward` `environment` as landed (including `admission`,
   `write-boundary`, `publication-failed`, `provider-failure` and `accepted-unpublished`), skips `counts_toward` null
   (`provider`, and build-continuation's interrupted categories), and is ended by `counts_toward` `item`. [from
   INTENT; re-derived at e65392cf]
   Reason: the landed table is the single classification contract (rule 44); a provider outage or a killed
   controller says nothing about the local environment; an item failure proves the environment let a Build run.
   Undo: let every non-environment report end the run, or count only category `environment`.
6. A fresh Build's first prompt carries the latest same-Intent, same-digest item report's `## First failure` block,
   rendered by the rework prompt's own renderer, plus a `Previous failure report:` line. Reports with a stop
   signature (`source: "stop"`) add no block. [12, part; stop-signature rule new at e65392cf]
   Reason: lesson 25; with the item breaker, the second try knows what the first failed on and a third is refused.
   A stop signature's `target` is a category, so the block's `Reproduce:` line would tell the Developer to run
   `make cannot-comply`.
   Undo: drop the block from the first prompt, or render stop signatures with no `Reproduce:` line.
7. No paid target; every proof is offline. [13, part]
   Reason: rule 49; breakers read files and the readiness probe is the fake harness's `auth status`.
   Undo: none needed.
8. The admission probe is `Kogen.Harness.open_roles(config, [:developer, :reviewer, :expert], control)` with no
   launch. The refusal and clear-file formats are fixed strings so tests match them whole. [new at e65392cf]
   Reason: the Build's own roles and route; with no launch, no Candidate or harness home is needed and the probe
   logs in the controller's cwd, which tests can observe. Shaping's `open_roles/2` reads the cwd as the project, which
   a Build doesn't.
   Undo: probe with the Build's launch after the Candidate exists (then a refusal would leave a Candidate).

## Audit

- Split 2026-09-27 at fa48e817 from the approved `durable-builds-and-failure-reports` (approved at f1d176b0, moved to
  drafts/ as a superseded reference). Two Builds of it ended with F1-F5 and F7 open. It was too big for one Build,
  and it named internal functions and arities, so the Reviewer judged shape instead of behaviour. The split keeps
  every behaviour and states it as observable outcomes (rule 43). There is no UX change.
- What moved here: the original scenarios item-breaker and environment-breaker, the admission order's breaker steps,
  the fresh Build's first prompt (from rework-prompt-inlines-first-failure (d)), risks readiness-blind-to-revocation
  and breaker-in-fixtures, and Assumed 1 and 7. Its final Build's F2 is this package's.
- Reshaped, not dropped: "`Tracking.approved_digest/1` becomes public" is now "computed the same way the tracking
  record computes it". "The refusal holds when the third Build is a fresh `mix kogen.build` OS process" is now proven
  by deleting a report file (the state is on disk). The refusal messages gain a fixed prefix so tests can match them.
- Order: build after failure-reports; build-continuation comes after this and adds reconcile and the continuation
  decision around these checks.
- Checked at fa48e817 (superseded by the re-preflight below): `Kogen.Harness.open_roles/4` (launch defaults to nil) and `close/1`; `check_complete_absent/2`
  and `acquire_lock/1` in `Kogen.Build.run/3`; `Tracking.approved_digest` is private; WorkspaceFixture ignores
  `.kogen/intents/approved/` and `.kogen/runtime/`; fake_codex saves `developer-launch-prompt`; fake_claude honours
  `FAKE_CLAUDE_LOGGED_OUT` and `FAKE_CHECK_FAIL_ALWAYS`; ledger rows in build_preconditions_test.exs (2) are kept.
- Re-preflight at e65392cf (2026-09-27), after failure-reports landed (commit e65392cf; also new since fa48e817:
  codex-developer-high bf28f2ca, custody stand-ins 098e4561, kogen-ctx d9013413, 8538b6a6 and 3531023d, none of which
  touch the admission path, the reports or the fixtures used here). Re-derived against the landed code:
  - Report location `FailureReport.report_path/2` = `<control>/.kogen/runtime/scenario-tracking/<build-id>/failure-report.json`;
    fields as listed in INTENT.md. `class` has four values; `counts_toward` is `item` for `shaping` too and JSON null
    for `provider`; `accepted-unpublished`, `admission`, `write-boundary`, `publication-failed` and
    `provider-failure` count toward `environment`. The Draft said an `item` "or `shaping`" report ends the run and
    named no environment categories; now stated as `counts_toward` values.
  - `same_signature_count` (private `same_signature_count/3`) counts regardless of `counts_toward` and is frozen at
    write time; the breaker recounts (Assumed 3). The landed `next_action` is already `reshape_details` from the
    second same-signature item report.
  - Admission: `Kogen.Build.run/3` → `acquire_lock/1` → `do_build/5` → `Tracking.new/5` → `admit_candidate/2` →
    `run_in_candidate/2`, whose `open_roles/1` step is the Build's readiness; its error becomes category
    `environment` through `readiness_reason?/1`. `check_complete_absent/2` is before the lock. `Tracking.approved_digest/1`
    is still private (sha256 of term_to_binary of the entries).
  - `Kogen.Harness.open_roles/4` (launch defaults to nil) and `close/1` unchanged. With no launch, `ClaudeCode`
    runs `auth status` without `cd`, so the fake logs to `<cwd>/.kogen/runtime/fake-harness-log`; `Kogen.Codex.open`
    with `KOGEN_HARNESS` set runs nothing (risk codex-probe-is-blind-in-fixtures).
  - The `## First failure` block is built inline in `FailureHandoff.render/1` (Target, First failure, Error head,
    Reproduce, then the sentence), so the first prompt must share it rather than copy it.
  - `publish_to_control/2` (after `Workspace.fast_forward/2` returns `:ok`) is where a Build publishes; publishing
    moves the Intent to Complete, so test 9 publishes the second Intent.
- Fixed: the Draft's "one byte of the Approved package's INTENT.md changes": the WorkspaceFixture package has no
  INTENT.md (intent.yaml and scenarios.yaml only); the tests append `# edited` to intent.yaml. The Draft's "no more
  `auth status` calls than an untripped Build" is now an exact `probe_lines` list per Build's own cwd. Hand-written
  provider report replaced by a real usage-limited Claude-route stop. "Shared first_failure" was too weak for the
  fixture (`check`), so the refusal also names the signature digest. Risk depends-on-failure-reports removed (landed).
- Probes (offline, under scratchpad bb/probe/, isolated KOGEN_WORKSPACES_ROOT for the last three; temp controls
  removed): env_probe.exs: three `FAKE_CLAUDE_LOGGED_OUT=1` Builds of two Intents stop as `environment`,
  `counts_toward` environment, `next_command` `mix kogen.claude.login`, stopped_at µs; `open_roles/4` with no launch
  logs exactly `argv: auth status` in the cwd and returns the readiness error. item_probe.exs: two fake_codex
  `FAKE_CHECK_FAIL_ALWAYS=1` Builds share one digest and package digest (target `check`, first_failure `check`,
  error_head `make: *** [check] Error 1`, reproduce null); two real cannot-comply stops get different digests; a
  Claude-route FAIL_ALWAYS Build is `offline-exhausted`; a logged-in Claude-route Build publishes (`:ok`).
  prompt_probe.exs: one fresh Developer launch per failing Build; its first prompt has no `## First failure` today.
  provider_probe.exs: a Claude-route Build with the be_n9crq session-limit tail stops as `provider`, counts_toward
  null.
- Existing tests swept at e65392cf: no test drives two matching item reports or three trailing environment reports
  into one control; no multi-Build test reads a later Build's first prompt; no test sets FAKE_CLAUDE_LOGGED_OUT; the
  only `cwd:` user asserts its third cwd holds only its sentinel (single Build, untripped). No existing test must
  change, so none is guarded; ledger rows in the listed files (controller_handoff t001-t019 less t011,
  build_preconditions t001-t002, scenario_lifecycle t010, commit_provenance t001, commit_failure_rollback t001) keep
  their names.
- Opus review at e65392cf: not ready (sweep sentence vs clear-file rule; KOGEN_HARNESS_HOME inherited in the Developer's own test run) → both fixed in INTENT.md; notes added.
