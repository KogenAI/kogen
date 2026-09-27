**Verdict: not ready**

The package is close. Both blocking findings are small text edits; nothing in the code design needs to change.

## Blocking findings

1. **The existing-test sweep contradicts the package's own clear-file rule** (`build-breakers/INTENT.md:360-361`, against `INTENT.md:137-139` and test 9 at `:290-291`).
   - The sweep says the hybrid setup is "provider-failure, then published: the run has one report, so there is no clear file".
   - The first hybrid Build's harness exits 3 with no provider marker. The controller reports that as "harness failure during Developer turn", which is category `provider-failure` (`lib/kogen/build.ex:2410`). That category counts toward `environment` (`lib/kogen/build/failure_report.ex:23,46`).
   - Under the package's own rule ("writes … `reason: published` when the environment run … is non-empty"), the publishing Build **does** write `environment-clear.json`. Test 9 relies on exactly that behaviour with a run of two.
   - `commit_failure_rollback_test.exs` does the same thing: `publication-failed` at `:152`, then `:ok` at `:160`. `INTENT.md:358-359` doesn't mention it.
   - Both tests still pass unedited. `runtime_tracking_records` only globs `*/record.json` (`commit_failure_rollback_test.exs:279`), and no hybrid assertion lists tracking directories. So only the sentence is wrong. But a Reviewer could quote it against correct code, or a Developer could special-case it.
   - **Fix:** say that both of these published Builds write a `published` clear file, and that no existing assertion reads it.

2. **`probe_lines(cwd)` fails whenever the Developer runs the tests inside its own turn** (`INTENT.md:114-117`, helper `:205-209`, test 7 `:266`/`:270`, test 10 `:304`).
   - Every Build launch sets `KOGEN_HARNESS_HOME` (`build.ex:535`). Codex's shell keeps the whole environment (`lib/kogen/codex/environment.ex:431`, `inherit="all"`), and the IsolatedCase child only adds variables on top of that (`test/support/isolated_case.ex:420-441`).
   - The no-launch `auth status` probe runs with the inherited environment plus the Claude changes (`claude_code.ex:159-173,433-434`), and those changes don't remove `KOGEN_*` variables.
   - `fake_claude:16` then logs to `$KOGEN_HARNESS_HOME/fake-state`, not to the cwd. In the Developer's own run, `probe_lines(cwd4)` and `probe_lines(cwd5)` come back `[]`, so tests 7 and 10 fail.
   - The controller's gate has no `KOGEN_HARNESS_HOME`, so they pass there. The Shaper's probe ran from Claude Code, which is why it didn't see this.
   - The likely first-try outcome is the Developer chasing a failure that doesn't exist, or "fixing" the probe in lib.
   - **Fix:** the Claude-route helper adds `{"KOGEN_HARNESS_HOME", nil}` to every Build's `env:`. `with_env` restores it afterwards.

## Notes (non-blocking)

- **Citations match the landed code:** `FailureReport.report_path/2`, `classify/1` and `counts_toward/1`, `FailureSignature.for_stop/2`, `run/3` → `acquire_lock/1` → `do_build/5` → `Tracking.new/5`, private `approved_digest/1` (`tracking.ex:677`), `check_complete_absent/2` before the lock, `publish_to_control/2` and `fast_forward/2`, `open_roles/4` with launch defaulting to nil, `Codex.open` running nothing when `KOGEN_HARNESS` is set, the `## First failure` block built inline in `FailureHandoff.render/1`, `stopped_at` in microseconds, and the `next_command` regex.
- **Wrong aside:** `INTENT.md:52-53` and `questions.md:25-26` say the third readiness stop of one Intent has `same_signature_count` 2. The readiness reason is fixed and the signature comes from `for_stop`, so it is existing + 1 = **3** (`failure_report.ex:184`). Nothing reads it.
- **Test 5:** item-breaker paths have no tie-break (`:95`), but the environment breaker ties by `build_id` (`:105`). Give the two hand-written reports distinct `stopped_at` values, or add the same tie-break for items.
- **Test 6:** the hand-written `other-1`/`other-2` reports have no `signature.source` or `target`. Because their source isn't `stop`, the latest one becomes the Build's first-prompt block, so the renderer has to cope with a nil `target`. Suggest giving them `target: "check"` and `source: "tail"`.
- **Timeouts:** IsolatedCase defaults to 120 s per test (`isolated_case.ex:13`). Tests 2, 3, 4 and 14 each run three full `fail_always` Builds, test 7 runs eight Builds, and test 9 runs six including a publish. Explicitly allowing `@tag timeout:` would remove the risk.
- **Existing-test sweep otherwise holds:**
  - No existing test puts two matching item reports or three trailing environment reports into one control.
  - Nothing sets `FAKE_CLAUDE_LOGGED_OUT`.
  - Every `fake-harness-log` check against a control or cwd is a refutation.
  - `developer-launch-prompt` is only read in single-Build fixtures.
  - `test-reliability.yaml` doesn't require rows for new tests (`scripts/check/README.md:221-226`).
  - Writing the second Intent keeps control clean: the verification fixture rewrites the same bytes.
- **`affected_paths` ⊆ `may_change_guarded_paths`:** holds in all four scenarios. The new test file is in `affected_paths`, so its selector is valid before it exists (`verification_plan.ex:536-537`). The catalog declares no integrity fields, so the proof selectors don't need to fail on base.
- **build-continuation:** only mentioned as future work (the reconcile step before the checks, and its null-counting categories). Nothing here depends on it.
- **Minor:** `existing-expectations-kept` `proof.offline` leaves out `core_integrity_test` and `harness_contract_test`, which `INTENT.md:363` names.

Unrelated: the claude.ai Stripe connector needs authorizing in your claude.ai connector settings before it can be used.
