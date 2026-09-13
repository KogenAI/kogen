# Complete evidence: Identify invalid Build handoff and Review entries

- Candidate id: `3372391050137564ef969ec4befa557b85920a01`
- Developer session id: `01a09944-ddee-79d2-91e2-15e93c982202`
- Reviewer session id: `01a0994a-c16e-7310-aaf5-4596de6d40fc`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-13T05:43:24Z`
- session_id: `01a09944-ddee-79d2-91e2-15e93c982202`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-5nhty972/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-5nhty972/process_group.dylib): 0.045s
Stage elapsed (mix format --check-formatted): 0.279s
Compiling 11 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.659s
+ mix credo --strict
+ mix test --exclude live
Checking 61 source files (this might take a while) ...
Running ExUnit with seed: 659435, max_cases: 12
Excluding tags: [:live]


Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.2 seconds (0.02s to load, 0.2s running 69 checks on 61 files)
712 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.664s
..............................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-55071-3332/missing-working-dir
...............................................................................................................................................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 37.4 seconds (37.4s async, 0.00s sync)

Result: 205 passed, 6 excluded
  6.914s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  6.659s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  6.362s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  5.476s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  5.148s Kogen.ScenarioSemanticTest test complete-looking source and partial-routing claims fail all required focused proofs
  4.467s Kogen.CommitFailureRollbackTest test restores the Approved Intent and leaves a clean worktree when git commit fails
  4.106s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  3.795s Kogen.SettlementRegressionTest test a corrected Check block cannot masquerade as a completed Developer turn
Stage elapsed (mix test --exclude live): 38.104s
Complete offline gate: 38.904s; exit=0
real 38.94
user 6.07
sys 5.01
  ```

## Declared targets

(none beyond `check`)

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"GWbHuF9FPqPwC8gMinEbt90drHLpHe4B","candidate_id":"3372391050137564ef969ec4befa557b85920a01","dispositions":[],"findings":[],"scenarios":[{"evidence":[{"locator":"validate_collection reports missing, blank, unexpected, duplicate, and non-object entries with one-based positions across handoff and verdict collections","path":"lib/kogen/build/contract.ex"},{"locator":"coverage diagnostics distinguish missing, duplicate, unexpected, blank, and malformed entries","path":"test/kogen/scenario_contract_test.exs"}],"id":"coverage-errors","reason":"All five scoped collections use actionable, per-entry coverage diagnostics rather than a roster-wide generic error.","status":"satisfied"},{"evidence":[{"locator":"entry, field, reference-position, path-safety, symlink, missing-file, and directory diagnostics","path":"lib/kogen/build/contract.ex"},{"locator":"handoff aggregation regression covers distinct field and reference causes","path":"test/kogen/scenario_contract_test.exs"}],"id":"entry-reference-errors","reason":"Entry validation identifies collection and entry context, field/reference position, supplied path, and specific local-file failure causes while retaining regular-file validation.","status":"satisfied"},{"evidence":[{"locator":"collection aggregation order and structural suppression in validate_collection, entry_errors, and reference_errors","path":"lib/kogen/build/contract.ex"},{"locator":"aggregates independent handoff field and reference causes without malformed-reference cascades","path":"test/kogen/scenario_contract_test.exs"}],"id":"aggregate-independent-errors","reason":"Independent collection, entry, field, and reference errors are accumulated deterministically; malformed entries and reference containers suppress dependent fabricated diagnostics.","status":"satisfied"},{"evidence":[{"locator":"handoff/verdict bindings, normalization, blocked-finding, and whole-verdict validation pipelines","path":"lib/kogen/build/contract.ex"},{"locator":"verdict entry diagnostics aggregate while valid reordered coverage remains accepted","path":"test/kogen/scenario_contract_test.exs"}],"id":"validity-unchanged","reason":"Existing binding, atom-key normalization, reordered coverage, optional collection, blocked-finding, and whole-verdict behavior remains in place.","status":"satisfied"},{"evidence":[{"locator":"handoff diagnostics reach the resumed Developer through the retained attempt","path":"test/kogen/scenario_lifecycle_test.exs"},{"locator":"handoff_diagnostics mode reads the preceding attempt failure and requires both detailed diagnoses before correction","path":"test/support/scenario_lifecycle_harness.py"},{"locator":"bound attempt has a passed Developer Stop Check receipt and valid recorded handoff","path":".kogen/runtime/scenario-tracking/petjQ-GckepL9IBnkA_dNH8X/record.json"}],"id":"handoff-error-delivery","reason":"The lifecycle control verifies retained directory and independent field diagnostics, same-session resumption, prior-attempt consumption, correction, fresh Check, and subsequent Review.","status":"satisfied"},{"evidence":[{"locator":"invalid Review retains all entry diagnoses and stops without publication","path":"test/kogen/scenario_lifecycle_test.exs"},{"locator":"verdict_diagnostics injects independent directory and unsafe-path reference failures","path":"test/support/scenario_lifecycle_harness.py"},{"locator":"receive_review passes Contract error text to stop, which records the complete failure without rework","path":"lib/kogen/build.ex"}],"id":"verdict-error-delivery","reason":"Malformed Review diagnostics flow through the real stop route into the returned error and retained failure; the lifecycle control verifies no publication, no extra rework, and no partial finding closure.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
