# Complete evidence: Continue shaping existing drafts in fresh sessions

- Candidate id: `ac02661d4f77860a5caeb169ca0e5dccb92be037`
- Developer session id: `01a0895c-1039-7210-8213-8275c6305e49`
- Reviewer session id: `01a08966-3d1d-74f3-9ed8-d060b09deba0`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-10T03:33:17Z`
- session_id: `01a0895c-1039-7210-8213-8275c6305e49`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-_1y_gp_e/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-_1y_gp_e/process_group.dylib): 0.062s
Stage elapsed (mix format --check-formatted): 0.296s
Compiling 8 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.609s
+ mix credo --strict
+ mix test --exclude live
Checking 45 source files ...
Running ExUnit with seed: 11790, max_cases: 12

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.1 seconds (0.01s to load, 0.1s running 69 checks on 45 files)
378 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Excluding tags: [:live]

Stage elapsed (mix credo --strict): 0.522s
........................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-89161-2056/missing-working-dir
..............................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 14.1 seconds (14.1s async, 0.00s sync)

Result: 118 passed, 4 excluded
  6.004s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  4.49s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  3.671s Kogen.HarnessRoleTest test every Codex launch overrides a hostile inherited role
  3.418s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  3.394s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.288s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
  3.121s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.047s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
Stage elapsed (mix test --exclude live): 14.718s
Complete offline gate: 15.490s; exit=0
real 15.54
user 4.13
sys 4.89
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 191142, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

....
Slowest individual offline cases (includes isolated process startup):

Finished in 372.7 seconds (372.7s async, 0.00s sync)

Result: 4 passed, 118 excluded
  229.359s Kogen.LiveShapeToBuildTest test real Shape continues a saved draft in a fresh session, then approval and Build complete the same Intent
  143.269s Kogen.LiveShapeToBuildTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  38.584s Kogen.LiveTest test developer session identity, exact resume, and a schema-valid reviewer verdict
  17.073s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
  0.0s Kogen.VerificationPolicyTest test the production PreToolUse policy blocks every covered explicit gate before fake dispatch
  0.0s Kogen.VerificationPolicyTest test missing policy data and invalid Bash input deny before fake dispatch
  0.0s Kogen.VerificationPolicyTest test focused tests and lookalikes reach the same fake dispatcher
  0.0s Kogen.VerificationPolicyTest test Build-side policy has fixed check/live ownership and validates hook registration

```

## Reviewer Verdict (structured, schema-valid)

```json
{"findings":[],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)
