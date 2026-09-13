# Complete evidence: Retain required target evidence independently of Reviewer citations

- Candidate id: `c83f339782ec37c2386f7d209df54d43b964bb50`
- Developer session id: `01a099c9-7029-7d61-b370-1c3816245242`
- Reviewer session id: `01a099e6-e4cd-7133-a22e-f0f76df1819f`
- Outer resumptions used: 1
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-13T08:33:56Z`
- session_id: `01a099c9-7029-7d61-b370-1c3816245242`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-s88pvh0w/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-s88pvh0w/process_group.dylib): 0.047s
Stage elapsed (mix format --check-formatted): 0.274s
Compiling 12 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.622s
+ mix credo --strict
+ mix test --exclude live
Checking 69 source files (this might take a while) ...
Running ExUnit with seed: 560447, max_cases: 12

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.2 seconds (0.02s to load, 0.2s running 69 checks on 69 files)
805 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.617s
Excluding tags: [:live]

.................................................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-78614-4354/missing-working-dir
..........................................................................................................................................................
Slowest individual cases (includes isolated process startup):

Finished in 35.1 seconds (35.1s async, 0.00s sync)

Result: 235 passed, 5 excluded
  20.324s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  8.234s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  7.645s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  5.842s Kogen.ScenarioSemanticTest test complete-looking source and partial-routing claims fail all required focused proofs
  5.389s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  4.591s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  4.188s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  3.968s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
Stage elapsed (mix test --exclude live): 35.817s
Complete offline gate: 36.571s; exit=0
real 36.59
user 6.65
sys 5.49
  ```

## Declared targets

(none beyond `check`)

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"SaAyJWZyPWiB_PAKsNUb1zro3c1JaiWg","candidate_id":"c83f339782ec37c2386f7d209df54d43b964bb50","dispositions":[{"evidence":[{"locator":"The public lifecycle's generated declared target invokes an opted-in `Kogen.IsolatedCase` producer; its first invocation forwards malformed plus valid frames and records the resulting declared-target failure before a subsequent valid receipt.","path":"test/kogen/lifecycle_test.exs"},{"locator":"`run!/3` forwards complete evidence frames, rejects required-frame absence, and preserves child failure precedence.","path":"test/kogen/isolated_target_evidence_test.exs"}],"id":"F1","reason":"Closed: the Candidate composes the macro/run! isolated producer with the production Build target path, and separately exercises malformed/duplicate forwarding and required-frame absence.","status":"closed"},{"evidence":[{"locator":"The reviewer fixture decodes the retained semantic artifact bytes and emits rework unless they equal the reviewed behavior.","path":"test/support/fake_codex"},{"locator":"The public lifecycle asserts initial semantically wrong retained bytes, same-Developer resumes, a distinct accepting Reviewer, and corrected retained bytes.","path":"test/kogen/lifecycle_test.exs"}],"id":"F2","reason":"Closed: the public lifecycle now derives blocking Review from retained artifact content, then proves same-Developer rework, fresh gates, and fresh acceptance.","status":"closed"}],"findings":[],"scenarios":[{"evidence":[{"locator":"Public lifecycle fixture installs an opted-in isolated producer and declared target; assertions inspect retained target evidence and confirm private sentinel suppression.","path":"test/kogen/lifecycle_test.exs"},{"locator":"Macro dispatch reaches `run!/3`, which forwards only complete evidence frames.","path":"test/support/isolated_case.ex"}],"id":"isolated-delivery","reason":"Satisfied: Build captures full declared-target output before receipt truncation, and the composed fixture verifies isolated frame delivery, retained entries, and suppression of bulk private output.","status":"satisfied"},{"evidence":[{"locator":"Retention test verifies manifest and both decoded artifact byte sequences, keeps the uncited binary out of Reviewer snapshots, removes runtime sources, and confirms Complete retains the same evidence.","path":"test/kogen/scenario_lifecycle_test.exs"},{"locator":"Capture snapshots exact bytes with path/digest and target-attempt provenance.","path":"lib/kogen/build/target_evidence.ex"}],"id":"mixed-retention","reason":"Satisfied: required artifacts are controller-retained independently of Reviewer citations and persist self-contained in Complete.","status":"satisfied"},{"evidence":[{"locator":"Strict parser tests cover malformed/duplicate frames, schema, duplicate path, unsafe path, missing/nonregular/symlink artifacts, and digest mismatch.","path":"test/kogen/target_evidence_test.exs"},{"locator":"Composed lifecycle records malformed-plus-valid forwarded frames as declared-target failure; isolated controls retain malformed/duplicate frames and reject required-frame absence.","path":"test/kogen/lifecycle_test.exs"}],"id":"invalid-evidence","reason":"Satisfied: invalid evidence is not treated as optional and becomes declared-target rework; focused and boundary controls cover the required malformed, path, and artifact failures.","status":"satisfied"},{"evidence":[{"locator":"`verify/2` validates decoded snapshot bytes and current bound source bytes, including containment and digest checks.","path":"lib/kogen/build/target_evidence.ex"},{"locator":"Build revalidates target evidence both with bound inputs and immediately before publication.","path":"lib/kogen/build.ex"},{"locator":"Controls cover source mutation, removal, decoded-byte forgery, and post-Review mutation preventing Complete publication.","path":"test/kogen/target_evidence_test.exs"}],"id":"frozen-evidence","reason":"Satisfied: bound evidence is revalidated against both retained decoded bytes and sources, and mutation/forgery controls prevent publication while preserving Approved input.","status":"satisfied"},{"evidence":[{"locator":"Reviewer fixture decodes retained semantic content and emits rework for the initial wrong bytes rather than accepting a manifest alone.","path":"test/support/fake_codex"},{"locator":"Lifecycle assertions prove wrong initial bytes, same Developer resumes, fresh Reviewer sessions, and corrected bytes after rework.","path":"test/kogen/lifecycle_test.exs"},{"locator":"Reviewer instructions require inspecting consequential retained artifacts and prohibit treating a manifest as semantic proof.","path":"priv/kogen/prompts/reviewer.md"}],"id":"semantic-rework","reason":"Satisfied: mechanically valid but semantically wrong retained content produces a blocking Review, then same-Developer rework, fresh verification, and fresh accepting Review.","status":"satisfied"},{"evidence":[{"locator":"No-frame output returns optional success; required-frame absence, forwarding, and child-failure precedence are explicitly implemented.","path":"test/support/isolated_case.ex"},{"locator":"Focused controls prove ordinary no-frame compatibility and that child failure remains authoritative after evidence forwarding.","path":"test/kogen/isolated_target_evidence_test.exs"},{"locator":"No-frame capture remains successful.","path":"test/kogen/target_evidence_test.exs"}],"id":"compatibility-cleanup","reason":"Satisfied: ordinary targets retain no-frame behavior, while required isolated producers and failed children cannot be converted into success by evidence forwarding.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
