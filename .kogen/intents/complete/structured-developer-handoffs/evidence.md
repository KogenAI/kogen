# Complete evidence: Enforce structured Developer handoffs

- Candidate id: `76a378929edb3667d4193bf183e691ee6db9116f`
- Developer session id: `01a09ee8-8f8e-7200-888b-bd6cefb51609`
- Reviewer session id: `01a09f15-b0c2-7783-a9a0-d298894e4447`
- Outer resumptions used: 2
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-14T08:37:44Z`
- session_id: `01a09ee8-8f8e-7200-888b-bd6cefb51609`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-pi1ci5pc/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-pi1ci5pc/process_group.dylib): 0.298s
Stage elapsed (mix format --check-formatted): 0.338s
Compiling 13 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.808s
+ mix credo --strict
+ mix test --exclude live
Checking 74 source files (this might take a while) ...
Running ExUnit with seed: 182413, max_cases: 12
Excluding tags: [:live]


Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.4 seconds (0.03s to load, 0.4s running 69 checks on 74 files)
852 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.850s
...............................................................................................................................................................................................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-70455-10882/missing-working-dir
...............................
Slowest individual cases (includes isolated process startup):

Finished in 60.9 seconds (60.9s async, 0.00s sync)

Result: 254 passed, 6 excluded
  25.707s Kogen.ShapingEvaluationTest test offline rehearsal exercises the maintained driver without provider access
  22.926s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  9.265s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  6.977s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  6.537s Kogen.IsolationCleanupTest test collection timeout awaits supervisor cleanup before removing its temporary root
  5.538s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  5.316s Kogen.SettlementRegressionTest test a corrected Check block cannot masquerade as a completed Developer turn
  5.1s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
Stage elapsed (mix test --exclude live): 61.783s
Complete offline gate: 62.799s; exit=0
real 62.84
user 7.20
sys 6.79
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 95107, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

....KOGEN_TARGET_EVIDENCE_MANIFEST	{"manifest_path":".kogen/runtime/shaping-evaluation-1789375073530-498/evidence-manifest.json","sha256":"6a93487816b92c3d5f3ae77d310a08ed033cb8f197a172fb19c9e13a46136a11"}
..
Slowest individual cases (includes isolated process startup):

Finished in 317.5 seconds (317.5s async, 0.00s sync)

Result: 6 passed, 254 excluded
  317.228s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  279.659s Kogen.LiveShapingEvaluationTest test five real public shaping sessions retain evidence and emit one manifest locator
  240.099s Kogen.LiveReviewerReworkTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  107.199s Kogen.LiveTest test independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart
  80.18s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  51.709s Kogen.NativeHelperLiveTest test a bounded fresh native dispatch records actual child routing evidence
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch

```

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"vz_HXPHqI7lV6zTbronVURuQHm6jPJX6","candidate_id":"76a378929edb3667d4193bf183e691ee6db9116f","dispositions":[{"evidence":[{"locator":"The retained accepted native Build attempt contains controller-owned `developer_invocation` schema, final message, SHA-256 bindings, diagnostics, session, and settled outcome.","path":".kogen/runtime/live-evidence/shape-to-build-42284-13253-1789374424260444833/scenario-tracking.json"},{"locator":"The current bound attempt records a passed `check` and passed `live` receipt for this Candidate.","path":".kogen/runtime/scenario-tracking/TLyhlgA-YgCmGHsLge5_essa/record.json"}],"id":"F1","reason":"closed: fresh native Build evidence now demonstrates retained invocation bytes after cleanup; the candidate source persists that evidence before handoff validation and Review.","status":"closed"}],"findings":[],"scenarios":[{"evidence":[{"locator":"`schema/3` creates a controller-derived strict object schema binding token, IDs, cardinalities, required properties, and extra-property rejection.","path":"lib/kogen/build/developer_handoff.ex"},{"locator":"The accepted native Build attempt retains a settled schema bound to its attempt token.","path":".kogen/runtime/live-evidence/shape-to-build-42284-13253-1789374424260444833/scenario-tracking.json"},{"locator":"Recorded Developer Stop `check` and declared `live` both passed for the Candidate.","path":".kogen/runtime/scenario-tracking/TLyhlgA-YgCmGHsLge5_essa/record.json"}],"id":"fresh-constraint","reason":"satisfied: Build generates and passes the strict current schema through its dedicated Developer launch route, retains the result, and applies the existing semantic validator before targets and Review.","status":"satisfied"},{"evidence":[{"locator":"Fresh and resumed paths both generate a schema and call the dedicated structured Developer APIs; resumed attempts retain the expected session check.","path":"lib/kogen/build.ex"},{"locator":"The native Reviewer-rework record retains two settled invocation payloads with one Developer session and distinct token-bound schemas.","path":".kogen/runtime/live-evidence/shape-to-build-42284-5259-1789374424260444833/scenario-tracking.json"},{"locator":"`developer_invocations!/4` audits the published two-attempt native record and session continuity.","path":"test/support/live_rework_audit.ex"}],"id":"stop-and-resume","reason":"satisfied: structured output survives the synchronous turn, and an outer rework resumes the same Developer with a newly derived schema and token.","status":"satisfied"},{"evidence":[{"locator":"Schema permits honest incomplete/blocked/disputed states while only constraining supported structural fields.","path":"lib/kogen/build/developer_handoff.ex"},{"locator":"`validate_handoff/5` delegates exact coverage, readiness, risk-link, and reference semantics to `Contract.handoff/4` before Review.","path":"lib/kogen/build.ex"},{"locator":"Offline controls cover duplicate, incomplete, unsafe-reference, and valid handoff paths.","path":"test/kogen/scenario_lifecycle_test.exs"}],"id":"semantic-authority","reason":"satisfied: schema enforcement is structural only; the established semantic and reference authority remains on the Contract path before Review.","status":"satisfied"},{"evidence":[{"locator":"Structural output failures are retained, categorized separately, and reworked through the existing same-session path; semantic failures use the same shared rework route.","path":"lib/kogen/build.ex"},{"locator":"Fixture tests exercise settled structural output failures and semantic handoff failures with exact-session correction.","path":"test/kogen/scenario_lifecycle_test.exs"},{"locator":"The exhaustion fixture asserts exactly two resume launches and no commit after the third non-accepting outcome.","path":"test/kogen/two_outer_resumptions_test.exs"}],"id":"bounded-correction","reason":"satisfied: structural and semantic handoff errors are distinguished, invalidate the prior Check through the normal attempt launch, consume the shared outer-resumption allowance, and do not create Review findings.","status":"satisfied"},{"evidence":[{"locator":"Structured transport reads only its newly owned final-output file after successful provider settlement and classifies provider failure separately from absent, empty, malformed, or truncated output.","path":"lib/kogen/harness.ex"},{"locator":"Build stops transport failures without rework and treats settled structural-output failures as correctable handoff failures.","path":"lib/kogen/build.ex"},{"locator":"Focused harness controls verify current-output authority, missing/empty/truncated cases, and provider-exit rejection.","path":"test/kogen/harness_verdict_test.exs"}],"id":"failed-or-stale-output","reason":"satisfied: no intermediate agent message or prior output is adopted; transport failure cannot become a successful or invented resumable handoff.","status":"satisfied"},{"evidence":[{"locator":"Private structured invocation directories are uniquely allocated, mode-restricted, retained through parsing, and removed only in the owned cleanup path.","path":"lib/kogen/harness.ex"},{"locator":"Invocation evidence is converted to controller-owned attempt data before semantic validation or rework.","path":"lib/kogen/build.ex"},{"locator":"The retained native rework record contains both exact schema/message/diagnostic payloads, hashes, session bindings, and settled outcomes.","path":".kogen/runtime/live-evidence/shape-to-build-42284-5259-1789374424260444833/scenario-tracking.json"}],"id":"owned-evidence","reason":"satisfied: required invocation bytes and bindings are retained in controller-owned records before private-directory cleanup, including distinct fresh and resumed invocation schemas.","status":"satisfied"},{"evidence":[{"locator":"Build-only structured Developer APIs are separate from the legacy non-Build Developer transport, while Reviewer retains its own route.","path":"lib/kogen/harness.ex"},{"locator":"Build calls only the explicit structured APIs for its Developer attempts.","path":"lib/kogen/build.ex"},{"locator":"Role tests and fake harnesses dispatch from `KOGEN_ROLE`, not output-schema flag presence.","path":"test/kogen/harness_role_test.exs"},{"locator":"The recorded gate result shows `check` and `live` passed for this Candidate.","path":".kogen/runtime/scenario-tracking/TLyhlgA-YgCmGHsLge5_essa/record.json"}],"id":"consumer-preservation","reason":"satisfied: Build has no unconstrained Developer fallback, while non-Build developer transport and role-based fake-provider routing remain available and verified.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Local archive receipt](scenario-tracking.json) records the original full tracking record’s byte count, SHA-256 and archive locator. The repository owner archived that oversized record outside Git on 2026-09-14 before publishing this commit. The concise original Build report above remains historical evidence; this checkout no longer includes the full self-contained record. The archived record is inspection evidence, not a recovery checkpoint.
