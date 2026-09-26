**NOT READY**

One gap remains, in B4. `test/kogen/unified_state_admission_test.exs` is now in the guarded list (`intent.yaml:52`) and in the `same-candidate-lifecycle` offline proof (`scenarios.yaml:72`). It is still missing from that scenario's `affected_paths` list (`scenarios.yaml:76-100`), and no other scenario's `affected_paths` includes it. Add it to the `same-candidate-lifecycle` `affected_paths` list.

The other two findings are resolved in the contract:
- **B1 (build lock recovery):** `.kogen/build.lock` is now an identity record owned by publication (`risks.yaml:26-29`). A later Build can take over a stale lock only when the lock and journal name the same Build; anything else is refused (`INTENT.md:11`, `scenarios.yaml:104`).
- **B2 (evidence before cleanup):** before a successful Candidate is removed, the controller copies the required verification and role evidence into control tracking, with content hashes and both explicit roots (`risks.yaml:15`, `INTENT.md:9`, `scenarios.yaml:64`).

One non-blocking note: if a Build crashes after taking the lock but before writing the journal, there is no matching journal, so the next Build refuses. It needs outside resolution, per `upgrade_behavior`. That fits the contract but is not stated explicitly.

Reconciliation: the missing affected path was added, and the pre-journal crash refusal is now stated explicitly in `INTENT.md`.
