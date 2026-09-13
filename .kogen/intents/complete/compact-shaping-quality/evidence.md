# Complete evidence: Improve shaping quality with five compact live cases

- Candidate id: `11915e1c979d9772a3834a0a79aa8afe51b8a675`
- Developer session id: `01a09b2e-0f5a-7963-81f7-fea113cda7c0`
- Reviewer session id: `01a09b3c-f376-7a62-b282-16a911fdcba6`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-13T14:42:06Z`
- session_id: `01a09b2e-0f5a-7963-81f7-fea113cda7c0`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen-compact-shaping-repair-2/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-7jprp5iy/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen-compact-shaping-repair-2/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-7jprp5iy/process_group.dylib): 0.054s
Stage elapsed (mix format --check-formatted): 0.300s
Compiling 12 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.686s
+ mix credo --strict
+ mix test --exclude live
Checking 72 source files (this might take a while) ...
Running ExUnit with seed: 101628, max_cases: 12
Excluding tags: [:live]


Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.3 seconds (0.03s to load, 0.3s running 69 checks on 72 files)
818 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.754s
..........................................................................................................................................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-23861-11266/missing-working-dir
..........................................................................
Slowest individual cases (includes isolated process startup):

Finished in 45.0 seconds (45.0s async, 0.00s sync)

Result: 244 passed, 6 excluded
  22.523s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  20.386s Kogen.ShapingEvaluationTest test offline rehearsal exercises the maintained driver without provider access
  11.865s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  8.233s Kogen.CommitFailureRollbackTest test restores the Approved Intent and leaves a clean worktree when git commit fails
  7.301s Kogen.ScenarioSemanticTest test complete-looking source and partial-routing claims fail all required focused proofs
  7.006s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  5.997s Kogen.IsolationCleanupTest test collection timeout awaits supervisor cleanup before removing its temporary root
  5.279s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
Stage elapsed (mix test --exclude live): 45.815s
Complete offline gate: 46.658s; exit=0
real 46.69
user 6.73
sys 5.36
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 282778, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

....KOGEN_TARGET_EVIDENCE_MANIFEST	{"manifest_path":".kogen/runtime/shaping-evaluation-1789310531463-42/evidence-manifest.json","sha256":"9afa4da703a6cb6f88f0120bf3b96fa719f58f99dacc96b1929d415a250e4883"}
..
Slowest individual cases (includes isolated process startup):

Finished in 327.4 seconds (327.4s async, 0.00s sync)

Result: 6 passed, 244 excluded
  327.23s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  281.695s Kogen.LiveShapingEvaluationTest test five real public shaping sessions retain evidence and emit one manifest locator
  241.692s Kogen.LiveReviewerReworkTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  123.579s Kogen.LiveTest test independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart
  66.037s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  48.967s Kogen.NativeHelperLiveTest test a bounded fresh native dispatch records actual child routing evidence
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch

```

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"Emjrx2ETlp0IvDnKKdz2ITc08wE-_3lo","candidate_id":"11915e1c979d9772a3834a0a79aa8afe51b8a675","dispositions":[],"findings":[],"scenarios":[{"evidence":[{"locator":"Retained CSV-flawed visible turns record the BOM/invalid-date discrepancy before the prescribed format answer and the final response preserves invalid-row and replacement decisions as undecided.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/csv-flawed/public-transcript.json"},{"locator":"Final saved questions mark BOM/input preservation settled while explicitly retaining invalid-row and output-recovery choices.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/csv-flawed/draft/questions.md"},{"locator":"Offline rehearsal owns the permission-rescue and pre-clarification probe controls.","path":"test/support/shaping_evaluation/driver_rehearsal_test.py"}],"id":"autonomous-csv-investigation","reason":"satisfied: the retained real session and final Draft show autonomous source-linked investigation before the only prescribed clarification, incorporation of the selected BOM policy, and preservation of both unresolved recovery choices.","status":"satisfied"},{"evidence":[{"locator":"Retained booking-flawed conversation identifies the absent historical connection, distinguishes adapter evidence from the actual route, and exposes the setup/audience choice before the supplied clarification.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/booking-flawed/public-transcript.json"},{"locator":"Final questions record the connected-organizer, per-run synthetic setup, collision, cleanup, and non-OAuth limits.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/booking-flawed/draft/questions.md"},{"locator":"Availability prerequisite control distinguishes empty output, unavailable authority, malformed/missing connection, collision refusal, and cleanup.","path":"test/support/shaping_evaluation/compact_prerequisites.py"}],"id":"usable-availability-and-verification","reason":"satisfied: the real retained case traces the stale setup gap, obtains the explicit narrower audience, and saves the synthetic-only verification and lifecycle limits rather than treating adapter success as real OAuth.","status":"satisfied"},{"evidence":[{"locator":"Both complete-case retained conversations save unapproved reviewable Drafts with no scripted replies and state that supplied facts settle consequential choices.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/csv-complete/review-receipt.json"},{"locator":"Complete availability case is captured as one root session with zero scripted replies and an unapproved saved Draft.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/booking-complete/review-receipt.json"},{"locator":"Driver rehearsal explicitly asserts zero replies for complete cases and prevents late initial-request rescue.","path":"test/support/shaping_evaluation/driver_rehearsal_test.py"}],"id":"complete-case-restraint","reason":"satisfied: both real complete cases advanced to unapproved reviewable packages without scripted confirmation; retained outcomes and Draft questions preserve the supplied scope and identify no unresolved consequential choice.","status":"satisfied"},{"evidence":[{"locator":"Visible continuation turns show supplied-direction handling, a partial invalid-row decision, the later separately requested replacement decision, and no approval move.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/csv-continuation/public-transcript.json"},{"locator":"Intermediate saved questions retain output replacement/recovery as unresolved after only the invalid-row answer.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/csv-continuation/drafts-by-turn/0/questions.md"},{"locator":"Final intent retains original identity, shaping metadata, baseline, and exactly one continuation entry.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/runs/csv-continuation/draft/intent.yaml"}],"id":"partial-answer-continuation","reason":"satisfied: retained intermediate and final artifacts show one continuation visit, original provenance preservation, an unapproved intermediate state with replacement still open, and a final state using the separately supplied replacement choice.","status":"satisfied"},{"evidence":[{"locator":"Live owner runs the real five-case suite, validates one manifest frame and its complete required artifacts, then forwards exactly that locator.","path":"test/kogen/live_shaping_evaluation_test.exs"},{"locator":"Collector launches five processes behind the shared barrier, validates each capture before manifest emission, and preserves failure/cancellation records instead of emitting a manifest on failure.","path":"test/support/shaping_evaluation/driver.py"},{"locator":"Retained live manifest enumerates the five cases' reviewable turn, Draft, source, seed, and intermediate artifacts.","path":".kogen/runtime/shaping-evaluation-1789310531463-42/evidence-manifest.json"}],"id":"five-case-evidence-delivery","reason":"satisfied: one live target receipt passed with one required-artifact manifest; inspected producer and consumer code and the retained manifest establish isolated concurrent case collection, required semantic artifacts, and single-frame delivery.","status":"satisfied"},{"evidence":[{"locator":"Offline owner executes native-binding, local-source, parser, and full maintained-driver rehearsal controls.","path":"test/kogen/shaping_evaluation_test.exs"},{"locator":"Rehearsal contains missing/late request, malformed turn, source mutation, capture, timeout, cancellation, and no-retry controls against the real driver boundary.","path":"test/support/shaping_evaluation/driver_rehearsal_test.py"},{"locator":"Project navigation documents check/live ownership and the actual driver, integrity consumer, refresh, cleanup, and semantic-review boundaries.","path":"test/support/shaping_evaluation/README.md"}],"id":"offline-rehearsal-and-preserved-routes","reason":"satisfied: the recorded passing check includes the maintained rehearsal, whose code drives real fixture preparation, YAML projection, public-transport boundary, collection, and consumer validation with the required negative controls; existing shape/continuation and lifecycle regressions remain in the passing gate.","status":"satisfied"},{"evidence":[{"locator":"Slow-start test requires readiness after PID/root prerequisites with a separate startup bound, then asserts timeout, descendant termination, and root removal; never-ready test asserts distinct readiness failure without reading markers.","path":"test/kogen/isolation_cleanup_test.exs"},{"locator":"Timeout fixture writes marker prerequisites, waits for the spawned descendant marker, delays startup, then signals readiness before collection timeout behavior.","path":"test/support/isolation_probe.exs"},{"locator":"Recorded Stop-hook check passed the updated isolation cleanup module within the full offline gate.","path":".kogen/runtime/scenario-tracking/HTLHPc86wgKKGHLe9D9S6GHA/record.json"}],"id":"cleanup-timeout-after-readiness","reason":"satisfied: the deterministic readiness-aware slow-start and never-ready assertions directly exercise the requested distinction without weakening descendant/root cleanup checks.","status":"satisfied"},{"evidence":[{"locator":"Fresh and continued role guidance requires explicit current-conversation approval, limits approval bookkeeping, preserves provenance, and rejects partial-answer approval.","path":"priv/kogen/prompts/shaping-continuation.md"},{"locator":"Real lifecycle fixture retains pre/post approval packages, checks protected fields and agreed requirements are unchanged, and audits failed-then-passed initial Stop history before first handoff.","path":"test/kogen/live_shape_to_build_test.exs"},{"locator":"Approval sequence performs a fresh continuation save, snapshots the unapproved package, sends explicit yes only afterward, and verifies approved presence plus Draft removal.","path":"test/support/shape_to_build_probe.exp"}],"id":"coherent-approval-to-build","reason":"satisfied: role instructions and the live lifecycle test together preserve explicit same-conversation assent, narrow package transition, initial in-turn Stop recovery, and bounded later independent review/rework.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
