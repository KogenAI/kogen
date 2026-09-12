# Complete evidence: Configure role models and unify delegation guidance

- Candidate id: `0690fb3562ff02276264f12e47a85fb6738d7138`
- Developer session id: `01a096f5-c496-76e1-af36-cb0af25a11ed`
- Reviewer session id: `01a09719-b03a-77f2-a374-14c0b9742d0f`
- Outer resumptions used: 2
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-12T19:22:45Z`
- session_id: `01a096f5-c496-76e1-af36-cb0af25a11ed`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-jp73org3/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-jp73org3/process_group.dylib): 0.044s
Stage elapsed (mix format --check-formatted): 0.276s
Compiling 11 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.613s
+ mix credo --strict
+ mix test --exclude live
Checking 61 source files (this might take a while) ...
Running ExUnit with seed: 35871, max_cases: 12

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.2 seconds (0.02s to load, 0.2s running 69 checks on 61 files)
Excluding tags: [:live]

703 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.605s
........................................................................................................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-56624-6338/missing-working-dir
...............................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 27.1 seconds (27.1s async, 0.00s sync)

Result: 199 passed, 6 excluded
  5.145s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  5.028s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  4.334s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  3.563s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.558s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.399s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.048s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  2.968s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
Stage elapsed (mix test --exclude live): 27.757s
Complete offline gate: 28.499s; exit=0
real 28.52
user 5.94
sys 6.70
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 432042, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

......

Slowest individual offline cases (includes isolated process startup):
Finished in 468.6 seconds (468.6s async, 0.00s sync)

Result: 6 passed, 199 excluded
  282.916s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  185.536s Kogen.LiveShapeToBuildTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  111.603s Kogen.LiveTest test independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart
  44.86s Kogen.NativeHelperLiveTest test a bounded fresh native dispatch records actual child routing evidence
  41.743s Kogen.LiveTest test developer session identity, exact resume, and a schema-valid reviewer verdict
  33.557s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch

```

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"euvZCuaqzb1Xh-sIpE2xp95aFKNh8Dko","candidate_id":"0690fb3562ff02276264f12e47a85fb6738d7138","dispositions":[],"findings":[],"scenarios":[{"evidence":[{"locator":"render/2; single owner for configured root/helper profile rendering","path":"lib/kogen/execution_policy.ex"},{"locator":"launch/4 expands shared policy for fresh and continued Shape","path":"lib/mix/tasks/kogen.shape.ex"},{"locator":"Developer and Reviewer prompt rendering calls ExecutionPolicy.render/2","path":"lib/kogen/build.ex"},{"locator":"Public lifecycle prompt assertions and distinct fixture profiles","path":"test/kogen/lifecycle_test.exs"}],"id":"shared-policy","reason":"All four public routes expand one shared policy through the same renderer. Templates retain approval, gate, read-only Candidate, and final-output authority. Public-route regressions cover expansion and unresolved placeholders; the recorded current Check passed.","status":"satisfied"},{"evidence":[{"locator":"All six selected profiles and outer_resumptions: 2","path":".kogen/config.yaml"},{"locator":"require_role/2, require_helpers/1, and require_string/3","path":"lib/kogen/intent.ex"},{"locator":"Fresh/continued Shape configuration, provenance, and pre-dispatch rejection tests","path":"test/kogen/shape_task_test.exs"},{"locator":"Distinct configured launch/resume arguments and root/helper prompt assertions","path":"test/kogen/lifecycle_test.exs"}],"id":"configured-profiles","reason":"Defaults match the approved table. Launch and resume pass configured root values directly; shared rendering maps helpers to explorer, worker, and default with explicit profiles. Required values are validated, and continuation preserves original provenance while recording the current visit.","status":"satisfied"},{"evidence":[{"locator":"Complete-task accounting, selective delegation, packet requirements, source verification, and role authority","path":"priv/kogen/prompts/execution-policy.md"},{"locator":"Cross-role policy obligations and authoritative completion contracts","path":"test/kogen/execution_policy_test.exs"}],"id":"bounded-delegation","reason":"The shared text includes the approved accounting, local-work, reuse, concurrency, ownership, stopping, citation, and integration obligations. It explicitly rejects mandatory fanout and automatic escalation while preserving independent root judgment.","status":"satisfied"},{"evidence":[{"locator":"launch_reviewer/3 preserves parse_turn errors; reviewer_response/2 validates completed verdicts","path":"lib/kogen/harness.ex"},{"locator":"Nonzero exit, provider error, incomplete turn, malformed verdict, and single-invocation controls","path":"test/kogen/profile_failure_test.exs"}],"id":"profile-failures","reason":"Reviewer transport failures retain their existing diagnostic errors without fallback or another invocation. Completed invalid responses still use malformed_verdict. Configuration validation prevents missing-profile inheritance, and shared guidance requires reporting native unavailability.","status":"satisfied"},{"evidence":[{"locator":"collect_receipt!/5, owned_children!/3, valid_child?/3, and fixture_unchanged?/2","path":"test/support/native_helper_fixture.ex"},{"locator":"Missing, mismatched, unrelated, incomplete, and changed-fixture negative controls","path":"test/kogen/native_helper_fixture_test.exs"},{"locator":"Three completed children; independently checked snapshot hashes, native parent IDs, and turn_context profiles","path":".kogen/runtime/live-evidence/native-helper-66214-770-1789240970443945208/native-receipt.json"}],"id":"native-helper-dispatch","reason":"The current live probe records all three configured helper profiles, supported kinds, expected deterministic facts, completion, and unchanged fixture inputs. Native snapshots corroborate the receipt; collector controls reject absent or contradictory evidence. Current Build-owned live verification passed.","status":"satisfied"},{"evidence":[{"locator":"Public Shape continuation, failed Stop correction, publication, and Reviewer rework tests","path":"test/kogen/live_shape_to_build_test.exs"},{"locator":"Exact three-argument route and generic invalid argument/profile controls","path":"test/support/scenario_semantic.ex"},{"locator":"Current public Shape-to-Build acceptance and same-session failed/passed Check evidence","path":".kogen/runtime/live-evidence/shape-to-build-66072-2890-1789240969612507083/evidence.md"},{"locator":"Two Sol-low Developer contexts in one session and two distinct Terra-medium Reviewer sessions; snapshot hashes and contexts independently checked","path":".kogen/runtime/live-evidence/shape-to-build-66072-5826-1789241252524587352/build-root-profile-audit/root-profile-receipt.json"}],"id":"live-continuity","reason":"Current retained evidence confirms public continuation and accepted publication, failed Stop correction, exact Developer resume, and fresh independent Review. Native root profiles match configuration, the two-resumption budget remains intact, and semantic fixture validation is repaired without weakening acceptance. Current Check and all six live tests passed.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
