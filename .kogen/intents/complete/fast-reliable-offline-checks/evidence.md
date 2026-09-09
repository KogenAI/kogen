# Complete evidence: Make the complete offline check fast and reliable

- Candidate id: `2db34a954bd0bf8f8da5e73d5c60cb4da717f55b`
- Developer session id: `01a08713-eaf3-71b2-980b-f451577309c2`
- Reviewer session id: `01a0871f-348d-7720-80a2-891724f9958e`
- Outer resumptions used: 0
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-09T16:57:41Z`
- session_id: `01a08713-eaf3-71b2-980b-f451577309c2`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-dt1g3j2l/process_group.dylib
Stage elapsed (mix format --check-formatted): 0.278s
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-dt1g3j2l/process_group.dylib): 0.277s
Compiling 8 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.614s
+ mix credo --strict
+ mix test --exclude live
Checking 45 source files ...
Running ExUnit with seed: 41930, max_cases: 12

Excluding tags: [:live]

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.2 seconds (0.02s to load, 0.1s running 69 checks on 45 files)
366 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Stage elapsed (mix credo --strict): 0.610s
.......................................................spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-20434-1346/missing-working-dir
.............................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 9.1 seconds (9.1s async, 0.00s sync)

Result: 116 passed, 4 excluded
  3.869s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  3.664s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.511s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.357s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.092s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  3.052s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
  2.888s Kogen.LifecycleTest test public Shape, explicit fixture approval, and public Build form one offline lifecycle
  2.774s Kogen.ApprovedMutationTest test rejects ignored Approved mutation during phase
Stage elapsed (mix test --exclude live): 9.768s
Complete offline gate: 10.546s; exit=0
real 10.60
user 4.16
sys 5.53
  ```

## Declared targets (beyond `check`)

### `make live`

```
mix test --only live
Running ExUnit with seed: 124968, max_cases: 12
Excluding tags: [:test]
Including tags: [:live]

....
Slowest individual offline cases (includes isolated process startup):

Finished in 299.0 seconds (299.0s async, 0.00s sync)

Result: 4 passed, 116 excluded
  159.452s Kogen.LiveShapeToBuildTest test real Shape drafts and is approved, then real Build corrects a real Stop-Check failure in one session and completes Review/Commit
  139.546s Kogen.LiveShapeToBuildTest test real reviewer rework resumes the same Developer and a fresh Reviewer accepts in a Build-only fixture
  33.898s Kogen.LiveTest test developer session identity, exact resume, and a schema-valid reviewer verdict
  15.735s Kogen.ColdOfflineTest test the complete offline gate passes with an empty private build cache
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
