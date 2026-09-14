# Complete evidence: Unify verification

- Candidate id: `8e398359ef291eba6e7c88545138da4dac68570f`
- Developer session id: `01a0a0ce-fa56-7b02-9bdf-7bcd7997b07a`
- Reviewer session id: `01a0a0e0-7cc8-7781-8561-e6daece7fc2e`
- Outer resumptions used: 1
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-14T16:59:20Z`
- session_id: `01a0a0ce-fa56-7b02-9bdf-7bcd7997b07a`
- output tail:
  ```
  /usr/bin/time -p python3 scripts/check/offline.py
Resolved Git executable: /Library/Developer/CommandLineTools/usr/bin/git
Offline gate: macOS-26.6.2-arm64-arm-64bit-Mach-O; installed dependencies; build path=_build; warm=True
Erlang/OTP 29 [erts-17.0.3] [source] [64-bit] [smp:12:12] [ds:12:12:10] [async-threads:1] [jit]

Elixir 1.20.2 (compiled with Erlang/OTP 29)
+ mix format --check-formatted
+ mix compile --warnings-as-errors --force
+ xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-687lf_1_/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-687lf_1_/process_group.dylib): 0.246s
Stage elapsed (mix format --check-formatted): 0.657s
Compiling 14 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 1.203s
+ mix credo --strict
+ mix test --exclude live
Checking 76 source files (this might take a while) ...
Running ExUnit with seed: 204137, max_cases: 12
Excluding tags: [:live]


Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.4 seconds (0.04s to load, 0.4s running 69 checks on 76 files)
872 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
.Stage elapsed (mix credo --strict): 1.010s
..................................................................................................................................................................................................................................................................
Slowest individual cases (includes isolated process startup):

Finished in 63.8 seconds (63.8s async, 0.00s sync)

Result: 259 passed, 6 excluded
  33.452s Kogen.ShapingEvaluationTest test offline rehearsal exercises the maintained driver without provider access
  22.506s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  15.774s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  14.473s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  8.647s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  6.047s Kogen.ShapeTaskTest test fresh and continued Shape reject invalid required profiles before harness dispatch
  6.041s Kogen.IsolationCleanupTest test collection timeout awaits supervisor cleanup before removing its temporary root
  5.209s Kogen.CommitFailureRollbackTest test restores the Approved Intent and leaves a clean worktree when git commit fails
Stage elapsed (mix test --exclude live): 64.794s
Complete offline gate: 66.184s; exit=0
real 66.22
user 7.90
sys 7.43

  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 87439, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

....KOGEN_TARGET_EVIDENCE_MANIFEST	{"manifest_path":".kogen/runtime/shaping-evaluation-1789405162561-530/evidence-manifest.json","sha256":"939d71913e86633c89fbffacb30358cdc0f29c2617d719220c4e70a9d8d34ce7"}
..
Slowest individual cases (includes isolated process startup):

Finished in 296.8 seconds (296.8s async, 0.00s sync)

Result: 6 passed, 259 excluded
  296.656s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  284.051s Kogen.LiveShapingEvaluationTest test five real public shaping sessions retain evidence and emit one manifest locator
  254.537s Kogen.LiveReviewerReworkTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  108.433s Kogen.LiveTest test independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart
  103.892s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  63.519s Kogen.NativeHelperLiveTest test a bounded fresh native dispatch records actual child routing evidence
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch

```

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"pUh-sUN0JSUkgzxjVA6-1FVJIX_21fMd","candidate_id":"8e398359ef291eba6e7c88545138da4dac68570f","dispositions":[],"findings":[],"scenarios":[{"evidence":[{"locator":"Attempt pUh-sUN0JSUkgzxjVA6-1FVJIX_21fMd records one passed cycle with check followed by live.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"},{"locator":"Unified runner deduplicates targets, ensures check first, and runs each target in order.","path":".codex/hooks/stop_runner.py"}],"id":"hook-ownership","reason":"The production hook owns ordered target dispatch; the recorded Stop cycle passed check then live without an outer rerun.","status":"satisfied"},{"evidence":[{"locator":"Admission test creates genuine failures then verifies deletion, corruption, rollback, and terminal replay make no further dispatch.","path":"test/kogen/unified_state_admission_test.exs"},{"locator":"Admission validates complete prior chronology and only increments failures for failed cycles.","path":".codex/hooks/stop_runner.py"}],"id":"shared-failures","reason":"The unified state machine carries one failure count across all targets and rejects damaged state before dispatch.","status":"satisfied"},{"evidence":[{"locator":"Verification validation resets failures only for a complete passed cycle; rework creates a new outer attempt with the same session.","path":"lib/kogen/build/verification.ex"},{"locator":"Public lifecycle fixture covers a Review rework and subsequent complete target cycle.","path":"test/kogen/verification_ownership_lifecycle_test.exs"}],"id":"third-pass","reason":"A complete passed cycle resets verification failures while outer rework remains independently tracked.","status":"satisfied"},{"evidence":[{"locator":"rework/4 compares monotonic attempt number to outer_resumptions and stops after the configured allowance.","path":"lib/kogen/build.ex"},{"locator":"Deterministic lifecycle fixture exercises Review rework with separate verification settlement.","path":"test/kogen/verification_ownership_lifecycle_test.exs"}],"id":"outer-limit","reason":"Outer rework accounting is independent of verification-cycle resets and is bounded by outer_resumptions.","status":"satisfied"},{"evidence":[{"locator":"Settlement preserves schema/output evidence, prioritizes exhausted verification, and routes only non-exhausted invalid handoffs through bounded rework.","path":"lib/kogen/build.ex"},{"locator":"Structured-output regression controls remain exercised by the offline gate recorded for this Candidate.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"handoff-preservation","reason":"The installed handoff validator and fresh-attempt schema flow remain in place while terminal verification takes precedence.","status":"satisfied"},{"evidence":[{"locator":"Cycle validation requires ordered complete successful receipts and derives failure progression from the prior cycle.","path":"lib/kogen/build/verification.ex"},{"locator":"Runner performs the full target sequence on each callback and short-circuits only at the failed target.","path":".codex/hooks/stop_runner.py"}],"id":"regression-bound","reason":"Each callback reruns the complete ordered sequence; partial success cannot reset V or outer rework accounting.","status":"satisfied"},{"evidence":[{"locator":"Runner rejects terminal state before target dispatch and emits continue:false only after persisting exhausted state.","path":".codex/hooks/stop_runner.py"},{"locator":"Production admission test asserts exhausted and deleted-exhausted replays leave dispatch markers unchanged.","path":"test/kogen/unified_state_admission_test.exs"}],"id":"native-exhaustion","reason":"Exhausted state is persisted and terminally rejected before handoff processing or any additional gate dispatch.","status":"satisfied"},{"evidence":[{"locator":"Runner snapshots manifest and every required artifact immediately while processing target output.","path":".codex/hooks/stop_runner.py"},{"locator":"Recorded live receipt contains a validated target-evidence manifest and retained required-evidence snapshots.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"evidence-forwarding","reason":"Target evidence is captured inside the hook completion path and retained in the controller receipt.","status":"satisfied"},{"evidence":[{"locator":"Runner validates state/history, bindings, chronology, and terminal status before candidate calculation or Make dispatch.","path":".codex/hooks/stop_runner.py"},{"locator":"Mutation matrix covers deleted, corrupt, rollback, exhausted, and deleted-exhausted state with zero replay dispatch.","path":"test/kogen/unified_state_admission_test.exs"}],"id":"binding-integrity","reason":"Unified callbacks fail closed on missing, malformed, rolled-back, inconsistent, or terminal state before targets run.","status":"satisfied"},{"evidence":[{"locator":"Build records verification context/state and preserves bound records through settlement, Review, and publication checks.","path":"lib/kogen/build.ex"},{"locator":"Recorded passed cycle is bound to the exact attempt token, Developer session, Candidate, and target receipts.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"preserved-authority","reason":"Controller-owned tracking and verification bindings remain separate from Developer-controlled work and are checked through publication.","status":"satisfied"},{"evidence":[{"locator":"Config requires verification_retries as a nonnegative integer alongside outer_resumptions.","path":"lib/kogen/intent.ex"},{"locator":"Tracked configuration supplies verification_retries: 2 without changing role profiles.","path":".kogen/config.yaml"}],"id":"config-contract","reason":"The new allowance is explicit, required, nonnegative, and configured independently from outer_resumptions.","status":"satisfied"},{"evidence":[{"locator":"Runner distinguishes unified versioned context from the legacy tracking context and rejects invalid unified context before dispatch.","path":".codex/hooks/stop_runner.py"},{"locator":"Build initializes and supplies versioned unified execution context for every new candidate attempt.","path":"lib/kogen/build.ex"}],"id":"self-build-transition","reason":"Legacy compatibility remains explicit while new-controller attempts receive initialized unified context and fail closed on incompatible state.","status":"satisfied"},{"evidence":[{"locator":"Stop hook timeout is 7200 seconds.","path":".codex/hooks.json"},{"locator":"Recorded live target passed and includes the live shaping-evaluation evidence manifest.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"lifetime-isolation","reason":"The Stop envelope was extended for live work, and the settled live receipt demonstrates the declared live route completed.","status":"satisfied"},{"evidence":[{"locator":"PreToolUse hook remains configured while Stop is separately routed through check.sh.","path":".codex/hooks.json"},{"locator":"Offline and live gate receipt reports passing VerificationPolicy covered-command controls.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"gate-guard","reason":"Moving execution into Stop retained the existing explicit-command guard and root-only hook path.","status":"satisfied"},{"evidence":[{"locator":"Receipt validation requires a parseable ISO-8601 finished_at for every target receipt.","path":"lib/kogen/build/verification.ex"},{"locator":"Settled Check and live receipts contain cycle-bound finished_at values.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"receipt-consumers","reason":"Unified receipts retain and validate real completion timestamps rather than substituting placeholders.","status":"satisfied"},{"evidence":[{"locator":"Shaping prompt includes the state-before-side-effect and observable control guidance.","path":"priv/kogen/prompts/shaping.md"},{"locator":"Live target’s retained evidence manifest includes the paired shaping-evaluation captures.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"shaping-state-guardrails","reason":"The maintained prompt and live retained evaluation evidence cover the flawed/complete state-guardrail pair.","status":"satisfied"},{"evidence":[{"locator":"Evaluation driver maintains paired captures, source integrity, consumer checks, and aggregate evidence manifest generation.","path":"test/support/shaping_evaluation/driver.py"},{"locator":"Settled live receipt retained the aggregate required-evidence manifest for the shaping evaluation.","path":".kogen/runtime/scenario-tracking/GdaB65MYvtpCP6WXJJD-bwc6/record.json"}],"id":"shaping-consumer-evidence","reason":"The maintained evaluation preserves source-consumer controls and forwards aggregate captured evidence through the live receipt.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Local archive receipt](scenario-tracking.json) records the original full tracking record’s byte count, SHA-256 and archive locator. The repository owner archived that oversized record outside Git on 2026-09-14 before publishing this commit. The concise original Build report above remains historical evidence; this checkout no longer includes the full self-contained record. The archived record is inspection evidence, not a recovery checkpoint.
