1. **Blocking — Candidate controller cannot take authority in this Build.**  
   **Scenarios:** `controller-owns-verification`, `failed-verification-resumes-same-developer`, `same-candidate-failed-only-retry`, `bound-per-target-receipts`.  
   **Evidence:** The package requires the new parent-controller path [scenarios.yaml:9-36](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:9>), but main initializes and settles its existing `Verification` module [build.ex:202-220](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build.ex:202>), injects `KOGEN_VERIFICATION_CONTEXT` into the Developer [build.ex:297-322](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build.ex:297>), and settles only Stop-written state [build.ex:621-653](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build.ex:621>). The package’s own investigation confirms this limitation [investigation.md:61-65](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/evidence/investigation.md:61>).  
   **Minimal fix:** Move the controller-cutover scenarios to a follow-up built under the new controller; make this package bootstrap-only.

2. **Blocking — The no-context Stop behavior contradicts main’s settlement path.**  
   **Scenario:** `stop-route-bootstrap-only`.  
   **Evidence:** The scenario requires no-context Stop to do nothing [scenarios.yaml:202-218](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:202>), but main’s Stop runner blocks without a session and otherwise runs Make and writes records [stop_runner.py:145-197](</private/tmp/claude-501/kogen-shape-fortify/kogen/.codex/hooks/stop_runner.py:145>). Main then requires that state to settle [build.ex:621-653](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build.ex:621>).  
   **Minimal fix:** Keep the current no-context Stop path for this Build and defer disabling it, plus the Stop-free fixture, to the follow-up.

3. **Blocking — Catalog changes are both unguarded and rejected by main.**  
   **Scenario:** `same-intent-catalog-change`.  
   **Evidence:** The scenario requires Makefile/catalog changes [scenarios.yaml:398-418](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:398>), but neither path is in `may_change_guarded_paths` [intent.yaml:51-80](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/intent.yaml:51>). Main rejects catalog changes after admission [build.ex:610-619](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build.ex:610>) and requires Make/catalog set equality [verification_plan.ex:136-149](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build/verification_plan.ex:136>).  
   **Minimal fix:** Remove this scenario from this package and defer it until a controller with declared catalog-change support is already running.

4. **Blocking — `check` is still hardcoded before Candidate code can change it.**  
   **Scenario:** `no-special-gate-target`.  
   **Evidence:** The scenario removes the mandatory `check` requirement [scenarios.yaml:336-360](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:336>), while main rejects a Makefile without `check` [build.ex:190-195](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build.ex:190>), validates the catalog as requiring `check` [verification_plan.ex:120-129](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build/verification_plan.ex:120>), and always prepends it to the plan [verification_plan.ex:67-73](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build/verification_plan.ex:67>).  
   **Minimal fix:** Defer this scenario, or rewrite it to describe main’s current mandatory-`check` contract.

5. **Blocking — New proof schema and ledger behavior cannot be loaded by main.**  
   **Scenarios:** `controller-runs-proof-selectors`, `verification-surface-ledger`.  
   **Evidence:** The package requires `proof.base` and controller-run proofs [scenarios.yaml:451-483](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:451>), but main’s contract parser rejects any proof key beyond the existing four [contract.ex:195-202](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build/contract.ex:195>). The ledger requires a new verdict key [scenarios.yaml:545-551](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:545>), while main’s exact-key parser rejects it [contract.ex:116-123](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build/contract.ex:116>).  
   **Minimal fix:** Defer these schema/ledger scenarios until their controller and parser are the Build baseline.

6. **Blocking — The required paid lifecycle test conflicts with main’s live target.**  
   **Scenario:** `controller-owns-verification`.  
   **Evidence:** The package says `live_shape_to_build_test.exs` will assert controller-owned history [scenarios.yaml:55-63](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/scenarios.yaml:55>), but the current paid test explicitly requires real Stop-hook history [live_shape_to_build_test.exs:378-401](</private/tmp/claude-501/kogen-shape-fortify/kogen/test/kogen/live_shape_to_build_test.exs:378>) and failed-then-passed Stop records [live_shape_to_build_test.exs:457-459](</private/tmp/claude-501/kogen-shape-fortify/kogen/test/kogen/live_shape_to_build_test.exs:457>).  
   **Minimal fix:** Leave this paid test on the old Stop contract in this Build; move the controller-history assertion to the follow-up.

7. **Blocking — A wrong implementation can pass every named proof.**  
   **Scenarios:** `controller-owns-verification`, `same-candidate-failed-only-retry`, `controller-runs-proof-selectors`, `verification-surface-ledger`.  
   **Evidence:** Missing selectors are checked only for existence [verification_plan.ex:94-103](</private/tmp/claude-501/kogen-shape-fortify/kogen/lib/kogen/build/verification_plan.ex:94>), while `make check` runs the broad suite rather than each selector [offline.py:21-26](</private/tmp/claude-501/kogen-shape-fortify/kogen/scripts/check/offline.py:21>). A Developer can add empty planned selector files, leave the old Stop controller untouched, and retain the existing live test, which still passes its Stop-history assertions.  
   **Minimal fix:** Require an end-to-end proof that main invokes each selector and exercises the claimed controller path, or defer these scenarios until that controller is baseline.

8. **Blocking — Scope and package text contradict themselves.**  
   **Scenarios:** `offline-first-target-selection`, `self-hosting-two-step-guidance`, `no-special-gate-target`, `same-intent-catalog-change`.  
   **Evidence:** Approved scope lists controller verification, receipts, reuse, hardcoded-check removal, catalog additions, proof tests, and ledger [intent.yaml:15-19](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/intent.yaml:15>), but the package adds two README/prompt-policy scenarios [INTENT.md:130-142](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/INTENT.md:130>) and simultaneously declares Makefile/catalog changes non-goals [INTENT.md:262-267](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/INTENT.md:262>).  
   **Minimal fix:** Remove the two policy scenarios and reconcile the catalog-change requirements with the stated non-goals and approval scope.

9. **Advisory — Stale or nonexistent references.**  
   **Scenario IDs:** package-wide.  
   **Evidence:** `references.yaml` points to absent runtime and draft paths [references.yaml:1-5](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/references.yaml:1>) [references.yaml:23-32](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/references.yaml:23>); the investigation says the revised package has seven scenarios [investigation.md:70-71](</private/tmp/claude-501/kogen-shape-fortify/kogen/.kogen/intents/drafts/fortify-paid-verification/evidence/investigation.md:70>) while `scenarios.yaml` contains twelve.  
   **Minimal fix:** Remove/update missing references and regenerate the investigation summary.

- **Proof selectors:** no additional selector finding; each selector either exists or is listed in its scenario’s `affected_paths` as a planned file.
- **Paid targets:** no unnecessary or missing paid target found; both paid targets correspond to edited live owners.