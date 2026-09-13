# Complete evidence: Make isolated test fixtures and child readiness reliable

- Candidate id: `23f2788630d2114b97126204fff45fc59d83ec46`
- Developer session id: `01a09984-c557-7291-b5ae-6a31ed2ddc55`
- Reviewer session id: `01a0999d-de18-7632-bf97-3583e9865f28`
- Outer resumptions used: 1
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-13T07:14:11Z`
- session_id: `01a09984-c557-7291-b5ae-6a31ed2ddc55`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-7zcld6ui/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-7zcld6ui/process_group.dylib): 0.274s
Stage elapsed (mix format --check-formatted): 0.337s
Compiling 11 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.755s
+ mix credo --strict
+ mix test --exclude live
Checking 62 source files (this might take a while) ...

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.3 seconds (0.03s to load, 0.3s running 69 checks on 62 files)
Running ExUnit with seed: 874034, max_cases: 12
738 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.751s
Excluding tags: [:live]

.................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-30926-10308/missing-working-dir
........................................................................................................................................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 38.7 seconds (38.7s async, 0.00s sync)

Result: 217 passed, 6 excluded
  19.829s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  9.177s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  6.776s Kogen.ScenarioSemanticTest test complete-looking source and partial-routing claims fail all required focused proofs
  6.668s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  4.816s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  4.025s Kogen.ScenarioLifecycleTest test handoff_unknown handoff blocks Review then corrects in the exact Developer session
  3.832s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  3.823s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
Stage elapsed (mix test --exclude live): 39.484s
Complete offline gate: 40.420s; exit=0
real 40.50
user 6.53
sys 6.45
  ```

## Declared targets

(none beyond `check`)

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"K48EyWOAJx9djmj9A1nQ1pd_y75CsjE8","candidate_id":"23f2788630d2114b97126204fff45fc59d83ec46","dispositions":[{"evidence":[{"locator":"Lines 90-105 execute every terminal behavior through the actual Harness.exec_shaper command in both pipe and PTY modes; lines 156-177 assert EOF, early-exit, missing-readiness, and failure diagnostics plus descendant termination.","path":"test/kogen/harness_role_test.exs"},{"locator":"Bound attempt K48EyWOAJx9djmj9A1nQ1pd_y75CsjE8 records a passed check for this exact Candidate at 2026-09-13T07:14:11Z.","path":".kogen/runtime/scenario-tracking/3-w55WLHGxrNBm9JyG6UAye7/record.json"}],"id":"F1","reason":"Closed: the previously absent actual Harness consumer coverage now exercises all required terminal outcomes in pipe and PTY modes, including owned-background cleanup.","status":"closed"}],"findings":[],"scenarios":[{"evidence":[{"locator":"copy!/2 rejects existing destinations, uses rsync --copy-links, and excludes dependency build products.","path":"test/support/dependency_fixture.ex"},{"locator":"Tests compile two private yamerl fixtures concurrently, retain the header, verify source/peer independence, and verify linked file and directory materialization.","path":"test/kogen/dependency_fixture_test.exs"},{"locator":"Bound attempt records a passed check for this exact Candidate.","path":".kogen/runtime/scenario-tracking/3-w55WLHGxrNBm9JyG6UAye7/record.json"}],"id":"private-dependency-sources","reason":"Private copies materialize linked data and omit caches; the concurrent compiler-consumer regression verifies independent usable copies without source or peer mutation.","status":"satisfied"},{"evidence":[{"locator":"copy!/2 lstat-preflights the destination before creation and rescues copy errors by removing only its newly created destination.","path":"test/support/dependency_fixture.ex"},{"locator":"Collision tests preserve directory, file, valid-link, and dangling-link destinations; negative controls cover broken links, cyclic links, and source-copy failure.","path":"test/kogen/dependency_fixture_test.exs"}],"id":"copy-refuses-collisions","reason":"Existing destination forms are rejected before mutation, while failed fresh source copies are removed and not returned.","status":"satisfied"},{"evidence":[{"locator":"run/3 creates a private readiness path; readiness collection uses separate monotonic startup and collection deadlines and maps startup timeout, early exit, and behavior timeout distinctly.","path":"test/support/isolated_case.ex"},{"locator":"The supervisor observes the marker before starting its behavior deadline and settles descendants before fixture removal.","path":"test/support/isolated_process.py"},{"locator":"Readiness tests cover delayed readiness, absent marker, early exit, post-ready timeout, stale foreign marker preservation, no-readiness compatibility, and macro dispatch.","path":"test/kogen/isolation_test.exs"}],"id":"isolated-readiness","reason":"The isolated route has separate readiness-aware timing phases with child-owned fresh markers, distinct failures, and retained cleanup behavior for direct and macro consumers.","status":"satisfied"},{"evidence":[{"locator":"The fake Shaper writes readiness from its child route and supplies delayed, EOF, early, missing, and background behaviors.","path":"test/kogen/harness_role_test.exs"},{"locator":"Lines 85-108 apply separate startup and post-ready deadlines while retaining an open stdin writer; cleanup terminates the process group and remembered owned PIDs.","path":"test/support/terminal_probe.py"},{"locator":"The actual Harness.exec_shaper matrix covers all outcomes in both pipe and PTY modes and asserts background descendant liveness after cleanup.","path":"test/kogen/harness_role_test.exs"}],"id":"terminal-readiness","reason":"Actual Harness.exec_shaper pipe and PTY consumers now distinguish delayed readiness, EOF waiting, early failure, and missing readiness, with cleanup asserted for successful and failing background work.","status":"satisfied"},{"evidence":[{"locator":"Existing regressions cover failure propagation, timeouts, parent cancellation, overlap, cwd/environment preservation, and descendant liveness.","path":"test/kogen/isolation_test.exs"},{"locator":"Cleanup regressions retain deletion-failure, timeout-settlement, setup-failure, and launcher-failure coverage.","path":"test/kogen/isolation_cleanup_test.exs"},{"locator":"Supervisor cleanup reaps descendants, confirms process-group disappearance, retains cleanup failures, and removes the private root only after settlement.","path":"test/support/isolated_process.py"}],"id":"cleanup-integrity","reason":"The maintained isolation cleanup controls remain present, while the readiness and terminal implementations retain owned-child settlement and cleanup-failure propagation.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
