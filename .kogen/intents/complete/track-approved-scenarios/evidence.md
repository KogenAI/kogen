# Complete evidence: Track Approved scenarios through independent Review

- Candidate id: `5aaf870f497b7b853d122f8ef08a2c12fb9a117e`
- Developer session id: `01a089ba-ed40-71e2-8438-fb650b7ab111`
- Reviewer session id: `01a089d1-ae8f-7462-b975-fd0cac3b79f3`
- Outer resumptions used: 1
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-10T05:29:23Z`
- session_id: `01a089ba-ed40-71e2-8438-fb650b7ab111`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-34co9fjz/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-34co9fjz/process_group.dylib): 0.049s
Stage elapsed (mix format --check-formatted): 0.283s
Compiling 10 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.703s
+ mix credo --strict
+ mix test --exclude live
Checking 53 source files ...
Running ExUnit with seed: 986344, max_cases: 12

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.2 seconds (0.02s to load, 0.2s running 69 checks on 53 files)
Excluding tags: [:live]

617 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.653s
...................................................................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-35863-3778/missing-working-dir
..................................................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 30.9 seconds (30.9s async, 0.00s sync)

Result: 181 passed, 5 excluded
  7.744s Kogen.ScenarioSemanticTest test complete-looking source and partial-routing claims fail all required focused proofs
  7.611s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  6.344s Kogen.CommitFailureRollbackTest test restores the Approved Intent and leaves a clean worktree when git commit fails
  6.223s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  5.195s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  4.996s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
  4.78s Kogen.ScenarioLifecycleTest test target failure preserves cumulative findings through the last allowed rework
  4.407s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
Stage elapsed (mix test --exclude live): 31.633s
Complete offline gate: 32.483s; exit=0
real 32.53
user 5.41
sys 5.76
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 85174, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

.....

Slowest individual offline cases (includes isolated process startup):
Finished in 448.0 seconds (448.0s async, 0.00s sync)

Result: 5 passed, 181 excluded
  267.821s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  180.158s Kogen.LiveShapeToBuildTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  120.873s Kogen.LiveTest test independent real Reviewer catches semantic fixture defects and accepts their corrected counterpart
  40.387s Kogen.LiveTest test developer session identity, exact resume, and a schema-valid reviewer verdict
  38.258s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch
  0.0s Kogen.VerificationPolicyTest test focused tests and lookalikes reach the same fake dispatcher

```

## Reviewer Verdict (structured, schema-valid)

```json
{"findings":[],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)
