# Complete evidence: Parallelize independent live cases and consolidate primitive probes

- Candidate id: `cfe75bef265188c9e806f0be56603efb6f4b6e2e`
- Developer session id: `01a099a8-e96e-70c1-9f5e-74dc7efb86af`
- Reviewer session id: `01a099b8-dcd7-7893-bfdc-e4f96d238f83`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-13T07:37:37Z`
- session_id: `01a099a8-e96e-70c1-9f5e-74dc7efb86af`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-8p8r205t/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-8p8r205t/process_group.dylib): 0.045s
Stage elapsed (mix format --check-formatted): 0.296s
Compiling 11 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.649s
+ mix credo --strict
+ mix test --exclude live
Checking 66 source files (this might take a while) ...
Running ExUnit with seed: 151773, max_cases: 12
Excluding tags: [:live]


Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.3 seconds (0.02s to load, 0.3s running 69 checks on 66 files)
761 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.708s
..........................................................................................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-61725-4546/missing-working-dir
........................................................................................................
Slowest individual cases (includes isolated process startup):

Finished in 35.2 seconds (35.2s async, 0.00s sync)

Result: 226 passed, 5 excluded
  18.063s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  11.503s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  4.68s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  3.835s Kogen.IsolationTest test readiness starts collection timing only after startup and diagnoses each phase
  3.734s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  3.382s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  2.915s Kogen.ScenarioLifecycleTest test rework reference bytes remain self-contained after the original runtime evidence disappears
  2.802s Kogen.DependencyFixtureTest test private dependency copies retain yamerl headers and compile concurrently
Stage elapsed (mix test --exclude live): 35.966s
Complete offline gate: 36.762s; exit=0
real 36.79
user 6.53
sys 5.99
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 524339, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

.....

Slowest individual cases (includes isolated process startup):
Finished in 362.5 seconds (362.5s async, 0.00s sync)

Result: 5 passed, 226 excluded
  362.391s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  236.227s Kogen.LiveReviewerReworkTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  134.537s Kogen.LiveTest test independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart
  48.005s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  44.514s Kogen.NativeHelperLiveTest test a bounded fresh native dispatch records actual child routing evidence
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch
  0.0s Kogen.VerificationPolicyTest test focused tests and lookalikes reach the same fake dispatcher

```

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"7qiYxEdcOOu1sECM1LxGitGHGnLVBtcX","candidate_id":"cfe75bef265188c9e806f0be56603efb6f4b6e2e","dispositions":[],"findings":[],"scenarios":[{"evidence":[{"locator":"Two distinct async ExUnit modules own the connected and rework cases; the rework lifecycle remains an independently invoked causal chain.","path":"test/kogen/live_shape_to_build_test.exs"},{"locator":"Offline isolated-dispatcher rendezvous proves concurrent owners, ordered outputs, propagated failure, cleanup, and source-layout control.","path":"test/kogen/live_scheduling_test.exs"},{"locator":"Recorded live receipt passed; connected and rework cases took 362.391s and 236.227s within a 362.5s suite, consistent with overlap.","path":".kogen/runtime/scenario-tracking/2UCBaAAV6gwphYKha2OIbNki/record.json"}],"id":"independent-live-overlap","reason":"The lifecycle owners are independently schedulable async modules, and the offline regression exercises the actual isolated dispatcher rather than a generic timing probe. Current declared live verification passed.","status":"satisfied"},{"evidence":[{"locator":"Session-bound stream audit requires exactly one started identity and completed event with a usage map, rejects provider failures, and validates reviewer receipt structure.","path":"test/support/live_native_receipt_audit.ex"},{"locator":"Positive and missing, wrong-session, incomplete, missing-usage, failed-event, and malformed-line controls.","path":"test/kogen/live_native_receipt_audit_test.exs"},{"locator":"Former primitive assertions are mapped to retained lifecycle, rework, and contract/profile owners.","path":"scripts/check/README.md"}],"id":"native-proof-consolidation","reason":"The standalone primitive route was removed only after its session, completion, usage, resume, reviewer-separation, and structured-verdict controls were moved to retained lifecycle owners and offline negatives. The recorded live run passed.","status":"satisfied"},{"evidence":[{"locator":"The retained rework owner directly composes the native receipt audit using its exact Developer and Reviewer identities.","path":"test/support/live_rework_audit.ex"},{"locator":"Owner-level corruptions cover incomplete completion, replacement identity, malformed Reviewer evidence, ordering, and exact resume.","path":"test/kogen/live_rework_audit_test.exs"},{"locator":"The scheduler failure control requires a nonzero child-suite result and verifies isolated cleanup.","path":"test/kogen/live_scheduling_test.exs"}],"id":"audit-failure-reaches-owner","reason":"The shared audit is invoked in retained owner paths; its exceptions are not ignored. Composed offline controls demonstrate owner failure for bad required evidence, while dispatch failure propagates and cleanup settles.","status":"satisfied"},{"evidence":[{"locator":"Connected Shape/continuation/approval/Build/Commit and separate Reviewer-rework lifecycle assertions, profile audits, and native summaries remain present.","path":"test/kogen/live_shape_to_build_test.exs"},{"locator":"Independent semantic Reviewer proof remains after primitive-probe removal.","path":"test/kogen/live_test.exs"},{"locator":"Recorded check passed with 226 offline tests; declared live receipt passed its five live cases including connected lifecycle, rework, semantic Review, native helper, and cold offline validation.","path":".kogen/runtime/scenario-tracking/2UCBaAAV6gwphYKha2OIbNki/record.json"}],"id":"retain-distinct-lifecycle-proof","reason":"Distinct connected, rework, semantic-review, native-helper, and cold-offline proof owners remain selected. Current receipts record successful check and live verification, and documentation retains the proof-owner and measurement-limit mapping.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
