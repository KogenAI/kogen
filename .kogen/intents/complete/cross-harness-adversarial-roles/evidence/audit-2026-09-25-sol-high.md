1. **Blocking — timeout rule contradicts itself and D8.** The package requires raising the compatibility turn limit from 240s to 300s (`INTENT.md:85-93`, `scenarios.yaml:222-225`, `risks.yaml:47-53`) while also forbidding any timeout increase (`INTENT.md:153-156,197`).  
   **Fix:** Remove the 300s requirement. Keep the existing limit and bound the work through the review packet/context changes; define a deterministic rerun cutoff within the unchanged 15-minute ceiling.

2. **Blocking — edited live owners are knowingly unverified.** The package edits `live_test.exs` and `live_shape_to_build_test.exs` but assigns only `[check]` and explicitly does not run either provider target (`INTENT.md:110-115`; `scenarios.yaml:189-203`; `risks.yaml:55-69`). A compile-only check cannot prove the new default-route behavior.  
   **Fix:** Defer those owner edits to Intent #4, or provide an allowed live proof that executes the affected owners. Do not claim this scenario is verified by `check`.

3. **Blocking — default-route effects omit new readiness/provider requirements.** The package says `live-shape-to-build` is affected only by the Reviewer moving to Codex (`INTENT.md:101-106`), but the same Intent adds Expert/auditor readiness (`INTENT.md:63-70`, `119-125`). The existing live owner assumes `config.harness` exists (`test/kogen/live_shape_to_build_test.exs:103-109`), and `live_test.exs` has the same assumption (`test/kogen/live_test.exs:208-216`).  
   **Fix:** Document and test the additional Codex readiness/role requirements, or constrain readiness to roles actually invoked by each owner.

4. **Blocking — required affected path is omitted.** `test/kogen/claude_code_catalog_test.exs` hard-codes the clean-route shape and `config.harness` (`test/kogen/claude_code_catalog_test.exs:43-52`), so changing the repository default to a hybrid requires updating it. No scenario lists that file (`scenarios.yaml:41,89,131,203,254`). `test/**` technically guards it, but the scenario impact declaration is incomplete.  
   **Fix:** Add `test/kogen/claude_code_catalog_test.exs` to `four-route-selection` (and refresh its ledger hash if changed).

5. **Blocking — plausible wrong implementation passes the named default-route proofs.** A Developer can update only `RootProfileAudit` and leave the live owners using the dominant/old profile table. The package’s offline selectors are only `root_profile_audit_test.exs` and `configuration_support_contract_test.exs`, while the actual provider owners are not run (`scenarios.yaml:189-203`; `Makefile:8-18`).  
   **Fix:** Execute the affected owner in an allowed paid target, or remove this behavior from the Intent and defer it to the owner that will run it.

6. **Blocking — frozen-role proof does not cover the complete frozen matrix.** The scenario requires freezing shaping, Developer, Reviewer, Expert, auditor, and helpers (`scenarios.yaml:99-111`), but the paid rework audit observes only the Developer and Reviewer stores (`scenarios.yaml:105-111,117-131`). A wrong implementation can re-read config for Expert/auditor after mutation and still pass the paid proof.  
   **Fix:** Add a deterministic mid-Build config-mutation test that invokes every role and helper context, including Expert and auditor, and asserts the frozen assignments.

7. **Blocking — the package plans for a mid-Build contract objection.** It admits Reviewer duration is unmeasured and instructs the Developer to return the Intent to Shaping if `live-reviewer-rework` times out (`risks.yaml:22-42`). The evidence also says only one Codex Reviewer run was dissected and variance is high (`evidence/reviewer-context-diagnosis-2026-09-25.md:62-68`).  
   **Fix:** Require a bounded paid probe after Intent #1 lands, with an explicit admission threshold, before this Build starts. Do not defer feasibility to `cannot_comply`.

8. **Blocking — baseline revalidation is a prerequisite without current evidence.** The package was shaped before Intent #1 and says the same files will change, requiring fresh validation on the post-#1 `main` (`intent.yaml:24-29`; `risks.yaml:71-81`; `INTENT.md:9-11`).  
   **Fix:** Block Build admission until a post-#1 validation receipt confirms `Intent.read`, `Contract.load`, `VerificationPlan.build`, `VerificationPolicy.preflight`, selector existence, and all #1 controls.

9. **Advisory — clean-route behavior is described as unchanged while adding auditor behavior.** The package says clean routes retain role behavior (`INTENT.md:57-62`) but also adds auditor resolution and Shape readiness to clean routes (`INTENT.md:63-70`; `scenarios.yaml:10-17`).  
   **Fix:** Say that existing four-role configuration bytes and behavior remain unchanged; explicitly document the new auditor readiness/launch plumbing.

10. **Advisory — catalog proof is under-selected.** `four-route-selection` claims catalog invariants (`scenarios.yaml:19-34`) but does not select `test/kogen/selective_verification_targets_test.exs`, which directly checks Make/catalog exhaustiveness and the absence of aggregate `live` (`test/kogen/selective_verification_targets_test.exs:22-30,78-108`). The controller separately freezes catalog bytes (`lib/kogen/build/verification_plan.ex:105`; `lib/kogen/build.ex:297-300`).  
    **Fix:** Add the direct catalog test to the offline proof, and state explicitly that `Makefile` and `priv/kogen/verification_targets.yaml` remain byte-frozen.