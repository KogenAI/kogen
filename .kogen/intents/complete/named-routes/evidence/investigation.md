# Shaping investigation at 6cdb2912 (2026-09-23)

Read-only source inspection by the controller, a scout (config consumer census)
and a worker (Build/Shape config flow). No probes executed, no source changed.

- Single config parser: `lib/kogen/intent.ex:56-64` (`read_config`),
  `:243-264` (`normalize_config`); proven-model check only for claude
  (`:91-103`), a no-op for codex.
- Build reads config once (`lib/kogen/build.ex:187`), holds it in `ctx`, passes
  launch contexts to every Developer/Reviewer call (`:293,303,583`), bakes
  `verification_retries` into the Stop verification context (`:249,264-268`);
  the Stop runner reads only that JSON (`.codex/hooks/stop_runner.py:29-45`).
- Re-reads from disk exist only in contextless fallbacks:
  `lib/kogen/harness.ex:121-128`, `lib/kogen/harness/claude.ex:454-461`,
  `lib/kogen/harness/codex.ex:178-181`.
- Setup CLIs read config: `lib/kogen/claude_code/cli.ex:32,39,59` (value
  ignored by `claude_code.ex:223,340`), `lib/kogen/codex/cli.ex:32,39,65`
  (used for helper profile files, tolerant of absence:
  `lib/kogen/codex/environment.ex:180-194`).
- Tracking record: `lib/kogen/build/tracking.ex:14` `@schema_version 1`;
  frozen fields at `:273`; no version-reading migration path.
- Draft continuation validation: `intent.ex:146` requires
  `shaping.{harness,model,effort,started}`; `Intent.read/2` does not inspect
  `shaping`. Continuation prompt already records visit
  harness/model/effort (`priv/kogen/prompts/shaping-continuation.md:32-45`).
- Flat config fixtures: 17 test files plus `test/support/compiled_fixture.exs:31-42`;
  exact config error strings asserted in `test/kogen/intent_test.exs:137,227,247,256,273`
  and `test/kogen/build_preconditions_test.exs:396`.
- Other config readers: live/native owners, `test/support/live_reviewer_rework_fixture.ex`,
  `test/support/root_profile_audit.ex:97`, `test/support/shaping_evaluation/driver.py:24,210`.
- Test reliability catalog binds test files by SHA-256
  (`scripts/check/refresh_test_reliability_sources.py`).
- Proof validator: `lib/kogen/build/verification_plan.ex:188-260`; the guard
  glob `test/support/**` does not match the bare path `test/support`, so
  affected paths name concrete files.

## Package validation probe (2026-09-23)

Command: `mix run --no-start .kogen/intents/drafts/named-routes/evidence/validate-package.exs`
(this script, run from the repository root against the Draft path).

- First run: `Kogen.Build.Contract.load` returned `:error`. The cause was a YAML
  parse error at `scenarios.yaml` line 18, column 117: an unquoted `": "` in
  `wrong_result`. Fixed by quoting values that contain `": "`.
- Second run: `Intent.read` ok; `Intent.read_draft` ok, so the Draft is accepted
  without `shaping.route` (routes do not exist yet); `Contract.load` ok;
  `VerificationPlan.build` ok with targets `[check, live-shape-to-build]`, the
  10 offline selectors plus `rehearse-live-shape-to-build`, and rehearsal
  `mix test --exclude live test/kogen/verification_ownership_lifecycle_test.exs`;
  4 risks parsed.
- Limitation: this shows the package passes Build's structural checks at
  `6cdb2912`. It says nothing about implementation feasibility.

## Test-compile warning probe (2026-09-23)

Disposable build path in the session scratchpad; no repository files changed.

1. Baseline: `MIX_BUILD_PATH=<scratch>/build MIX_ENV=test mix test --only kogen_shaping_probe_no_such_tag --warnings-as-errors`
   loaded every test file (390 tests excluded). Result: 0 `warning:` lines. The exit
   status was 1 only because `--only` matched no test ("no test was executed").
   Conclusion: the suite has no test-compile warnings at `6cdb2912`.
2. Negative control: `evidence/stale_live_owner_probe_test.exs` (a `@moduletag :live`
   test calling `Kogen.Harness.launch_reviewer/5`, which does not exist):
   - `mix test --exclude live <file>` gave exit 0 with the warning
     "Kogen.Harness.launch_reviewer/5 is undefined or private".
   - Adding `--warnings-as-errors` gave exit 1, "Test suite aborted after
     successful execution due to warnings".
   This confirms the review's probe. Limitation: it was run on the file alone,
   not through `offline.py`.
