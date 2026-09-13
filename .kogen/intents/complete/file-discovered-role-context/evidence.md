# Complete evidence: Discover role context from files across all phases

- Candidate id: `b7a40d58c405bef263f9925c276366d104433d6e`
- Developer session id: `01a0992a-ef9b-7f12-ba6b-34f014f9d305`
- Reviewer session id: `01a09935-cd04-7710-91af-de455f8e61bb`
- Outer resumptions used: 1
## Check (Stop hook Verification Record, bound to this Candidate)

- status: `passed`
- exit_code: `0`
- finished_at: `2026-09-13T05:20:31Z`
- session_id: `01a0992a-ef9b-7f12-ba6b-34f014f9d305`
- output tail:
  ```
  + xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-s1ts4zpd/process_group.dylib
Stage elapsed (xcrun clang -dynamiclib -Wall -Werror /Users/almirsarajcic/Projects/AppBuilder/kogen/test/support/process_group.c -o /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-check-support-s1ts4zpd/process_group.dylib): 0.256s
Stage elapsed (mix format --check-formatted): 0.333s
Compiling 11 files (.ex)
Generated kogen app
Stage elapsed (mix compile --warnings-as-errors --force): 0.790s
+ mix credo --strict
+ mix test --exclude live
Checking 61 source files (this might take a while) ...
Running ExUnit with seed: 749302, max_cases: 12

Please report incorrect results: https://github.com/rrrene/credo/issues

Analysis took 0.3 seconds (0.03s to load, 0.2s running 69 checks on 61 files)
705 mods/funs, found no issues.

Use `mix credo explain` to explain issues, `mix credo --help` for options.
Excluding tags: [:live]

Stage elapsed (mix credo --strict): 0.737s
.......spawn: Could not cd to /var/folders/r7/0tzq_ynx5qn9ny3km3xlxhzm0000gn/T/kogen-isolation-probe-32788-135/missing-working-dir
.................................................................................................................................................................................................
Slowest individual offline cases (includes isolated process startup):

Finished in 31.3 seconds (31.3s async, 0.00s sync)

Result: 200 passed, 6 excluded
  6.137s Kogen.ScenarioLifecycleTest test exhaustion preserves unique records without raw logs and publication copies closure evidence
  5.158s Kogen.VerificationOwnershipLifecycleTest test Stop owns fresh Check while outer Build owns ordered gates across gate and Reviewer rework
  4.818s Kogen.ScenarioSemanticTest test complete-looking source and partial-routing claims fail all required focused proofs
  4.749s Kogen.ShapeTaskTest test invalid selections fail before harness launch
  4.541s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
  4.053s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
  3.84s Kogen.ScenarioLifecycleTest test handoff_duplicate handoff blocks Review then corrects in the exact Developer session
  3.608s Kogen.CoreIntegrityTest test preserves core integrity for each scenario
Stage elapsed (mix test --exclude live): 32.129s
Complete offline gate: 33.142s; exit=0
real 33.24
user 6.10
sys 5.53
  ```

## Declared targets

(none beyond `check`)

## Reviewer Verdict (structured, schema-valid)

```json
{"attempt_token":"ruThqKqPsts6vjqS097dWPh4x5AjcC8q","candidate_id":"b7a40d58c405bef263f9925c276366d104433d6e","dispositions":[{"evidence":[{"locator":"developer_prompt/2 renders the complete developer template on both first and resumed dispatches before adding concise feedback and the locator packet.","path":"lib/kogen/build.ex"},{"locator":"public lifecycle test captures the resumed provider-boundary prompt and asserts role instructions, authority, schema, concise feedback, and absence of the bulk sentinel.","path":"test/kogen/lifecycle_test.exs"}],"id":"F1","reason":"The resumed Developer route now includes the full Developer role template and structured handoff schema while retaining only concise rework metadata and path-based task context.","status":"closed"}],"findings":[],"scenarios":[{"evidence":[{"locator":"all-role-dispatch scenario defines the five-route locator and non-growth contract.","path":".kogen/intents/approved/file-discovered-role-context/scenarios.yaml"},{"locator":"Lifecycle assertions inject more than 1 MiB of retained evidence, capture first/resumed Developer and both Reviewer prompts, and assert bulk content is absent; Shape tests cover fresh and continued Shape sentinels.","path":"test/kogen/lifecycle_test.exs"},{"locator":"Fresh and continuation Shape tests assert maintained file-body sentinels are absent while identity, profile, provenance, and optional-content guidance remain present.","path":"test/kogen/shape_task_test.exs"}],"id":"all-role-dispatch","reason":"Production Build appends a compact locator packet to complete static Developer and Reviewer role prompts, including resumed Developer dispatch; production Shape routes retain their file-discovery instructions without embedding maintained-file bodies.","status":"satisfied"},{"evidence":[{"locator":"task_context/3 supplies approved-package and tracking-record paths, working directory, attempt token, Candidate id, and Developer session identity to both roles.","path":"lib/kogen/build.ex"},{"locator":"The fixture reader opens the authoritative record, validates current attempt/Candidate bindings, derives open findings, and rejects unreadable or stale data.","path":"test/support/scenario_response.py"},{"locator":"Negative controls prove a changed linked requirement changes the verdict and that stale attempt, wrong Candidate, and missing record locators fail.","path":"test/kogen/scenario_response_test.exs"}],"id":"discovered-contract","reason":"The candidate delivers only bound locations and identities; the provider fixtures independently read the current record and linked requirement/source, with tested negative controls preventing call-count-only acceptance.","status":"satisfied"},{"evidence":[{"locator":"resume_feedback/2 provides only failure category and authoritative record location; developer_prompt/2 supplies the full role contract and current locator packet.","path":"lib/kogen/build.ex"},{"locator":"Public lifecycle exercises invalid handoff, Reviewer rework, exact Developer resume, repair, fresh Reviewer acceptance, closed finding, oversized retained record, and publication.","path":"test/kogen/lifecycle_test.exs"},{"locator":"Tracking tests preserve finding origin/disposition history and distinguish Developer and Reviewer exact-byte snapshots.","path":"test/kogen/scenario_tracking_test.exs"}],"id":"rework-and-history","reason":"Rework remains concise and points to retained detail; tests cover same-session resumption, source-directed repair, fresh review, finding closure, and preservation of historical tracking bindings.","status":"satisfied"},{"evidence":[{"locator":"Current bound attempt has the supplied token and Candidate id, with a passed Stop-hook Check receipt (exit 0) for that same Candidate and Developer session.","path":".kogen/runtime/scenario-tracking/EiHEBIINMjhfOq8HzA7P4ein/record.json"},{"locator":"Reader rejects unreadable records and stale attempt/Candidate bindings rather than inventing context.","path":"test/support/scenario_response.py"},{"locator":"Tracking integrity tests reject external mutation, preserve exact-byte references, retain finding history, and permit omitted optional risks.","path":"test/kogen/scenario_tracking_test.exs"}],"id":"integrity-preserved","reason":"Existing binding, record-integrity, finding, receipt, publication, and optional-content controls remain in place; the locator implementation adds explicit rejection of missing or stale authoritative inputs.","status":"satisfied"}],"verdict":"accept"}
```

- Reviewer verdict: accept
- Reviewer findings: (none)

## Scenario closure

[Self-contained scenario tracking](scenario-tracking.json) contains requirements, claims, owned receipts, independent assessments and retained finding history. This evidence is not a recovery checkpoint.
