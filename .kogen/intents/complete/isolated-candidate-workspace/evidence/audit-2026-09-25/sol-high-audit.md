1. **Blocking — package lifecycle is contradictory and not buildable from its current location.**  
   **Evidence:** [intent.yaml:4,77-94](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:4) marks the package `draft` while recording approval; [approval.md:24-26](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/approval.md:24) says it still must be moved to `approved/`; `Build.run` reads only `.kogen/intents/approved` ([lib/kogen/build.ex:50-53](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/build.ex:50)).  
   **Why:** This package cannot be admitted as stored.  
   **Fix:** Reconcile approval/status and move it only after the stated then-main recheck, or remove approval metadata and keep it explicitly draft.

2. **Blocking — required shaping provenance is incomplete.**  
   **Evidence:** The format requires `shaping.route` ([priv/kogen/prompts/shaping.md:149-154](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/priv/kogen/prompts/shaping.md:149)); current `intent.yaml` has no route ([intent.yaml:24-28](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:24)).  
   **Why:** The package does not satisfy the maintained Intent schema.  
   **Fix:** Add the actual route for the original shaping visit and preserve it through continuations.

3. **Blocking — `controller-judges-candidate` cannot reach the asserted verification path.**  
   **Evidence:** The scenario mutates Candidate hook files and expects a failed receipt/resume ([scenarios.yaml:147-168](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:147)); those paths are outside the guarded list ([intent.yaml:146-164](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:146)); `GuardedPaths.check` rejects any changed path outside guards before verification ([lib/kogen/build/guarded_paths.ex:16-26](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/build/guarded_paths.ex:16)).  
   **Why:** The Build stops on the guard error; it does not run `make check`, record a receipt, or resume.  
   **Fix:** Make hook tampering a separate preflight negative-control test, or change the scenario to expect fail-closed guard rejection. Do not add hooks to the guards under D9.

4. **Blocking — Codex scope immutability contradicts the existing adapter.**  
   **Evidence:** The scenario requires the Codex scope file list to remain identical ([scenarios.yaml:65-71](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:65)); `Environment.prepare/6` creates `environments.toml` and `agents/kogen_boundary.toml` in `CODEX_HOME` ([lib/kogen/codex/environment.ex:68-75](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/codex/environment.ex:68), [220-250](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/codex/environment.ex:220), [262-303](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/codex/environment.ex:262)).  
   **Why:** A fresh scope necessarily changes during a Build, so the stated proof fails.  
   **Fix:** Pre-seed and exclude those deterministic Kogen files from the snapshot, while asserting credential and native-session/rollout integrity; or redesign the Codex storage boundary.

5. **Blocking — publication cleanup has no coherent failure state.**  
   **Evidence:** Publication removes the Approved copy, then removes the Candidate, but says an untracked file causes removal refusal while `B` is still published ([scenarios.yaml:221-231](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:221)).  
   **Why:** After fast-forward, the Candidate can remain with no defined owner/disposition, while the Approved copy is already gone.  
   **Fix:** Define a `published-retained`/cleanup-pending state, preserve the owner record, and make cleanup retryable; test failure after fast-forward separately.

6. **Blocking — Candidate removal semantics contradict themselves.**  
   **Evidence:** The command scenario says every accepted-unpublished Candidate requires `--discard-accepted` ([scenarios.yaml:343-348](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:343)); the Intent says the flag is required only when the commit is unreachable from the admitted branch ([INTENT.md:200-207](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:200)).  
   **Why:** Reachable accepted commits have two different specified behaviors.  
   **Fix:** State and test the exact matrix: reachable without flag; unreachable only with `--discard-accepted`.

7. **Blocking — several offline selectors are intentionally nonexistent, and the current proof mechanism checks existence only.**  
   **Evidence:** New selectors are listed as future files ([INTENT.md:326-330](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:326)); examples include `build_workspace_test.exs`, `harness_home_test.exs`, `candidate_verification_test.exs`, and `candidates_command_test.exs` ([scenarios.yaml:39-40](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:39), [97](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:97), [171](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:171), [361](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:361)); `missing_selectors/3` only checks `File.exists?` ([lib/kogen/build/verification_plan.ex:84-103](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/build/verification_plan.ex:84)).  
   **Why:** A weak test can satisfy handoff and `check` without observing Candidate routing or isolation.  
   **Fix:** Add the files before approval, or require controller-owned focused execution and meaningful negative controls for every new selector.

8. **Blocking — a plausible wrong implementation can pass the named proof surface.**  
   **Wrong implementation:** Set `KOGEN_PROJECT_ROOT` and task-context paths to the Candidate, but leave the actual native process cwd and some controller `File.cwd!()` reads on control; add weak selectors that assert only environment variables.  
   **Evidence:** `RootProfileAudit` validates model/effort but not expected cwd ([test/support/root_profile_audit.ex:132-155](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/test/support/root_profile_audit.ex:132)); the paid test invokes it without a cwd assertion ([test/kogen/live_shape_to_build_test.exs:354-360](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/test/kogen/live_shape_to_build_test.exs:354)); proof selectors are existence-checked as above.  
   **Fix:** Record and assert actual OS cwd and Git toplevel from every native role, and run focused selectors through the controller against Candidate-only sentinels.

9. **Blocking — D9 root selection is underspecified at existing call sites.**  
   **Evidence:** The scenario says preflight must inspect Candidate hooks ([scenarios.yaml:155-158](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:155)); current Build calls `VerificationPolicy.preflight` without a root ([lib/kogen/build.ex:297-301](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/build.ex:297)); the policy defaults to `"."` ([lib/kogen/verification_policy.ex:27-34](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/verification_policy.ex:27)).  
   **Why:** Depending on ambient cwd can inspect control instead of Candidate, while settings are loaded from an absolute control path ([lib/kogen/harness/claude.ex:109-135](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/lib/kogen/harness/claude.ex:109)).  
   **Fix:** Pass explicit control and Candidate roots at every boundary and test both roots from a third cwd.

10. **Advisory — Codex credentials are referenced safely, but Codex rollouts remain shared.**  
    **Evidence:** The design keeps `CODEX_HOME` as the scope ([INTENT.md:91-94](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:91)); the probe states auth and rollouts live there ([evidence/harness-home-credential-probe-2026-09-25.md:100-111](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/evidence/harness-home-credential-probe-2026-09-25.md:100)).  
    **Why:** Login loss is unlikely, but Codex session history and native writes can be visible across Builds, so this is not full per-Build harness isolation.  
    **Fix:** State that only operation state is per-Build, or provide a supported separate auth/session scope.

11. **Advisory — the guarded paths are broader than the self-hosting change needs.**  
    **Evidence:** `lib/kogen/build/**`, `lib/kogen/harness/**`, `test/kogen/**`, and `test/support/**` are all writable ([intent.yaml:149-164](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:149)).  
    **Why:** This permits unrelated controller, fixture, and test changes during a self-hosted Build.  
    **Fix:** Enumerate exact modules and fixtures, especially files used by the paid target; let the verification-surface ledger handle unrelated edits.

12. **Advisory — the single paid target is policy-compliant but leaves meaningful paths unrun.**  
    **Evidence:** The package selects only `live-shape-to-build` ([scenarios.yaml:85-105](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:85)); the risk explicitly leaves `live-reviewer-rework` and `live-general` unrun ([risks.yaml:122-129](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/risks.yaml:122)).  
    **Why:** D8 supports one lifecycle target, but the dedicated Reviewer-rework Build is the direct provider exercise of same-Candidate Review rework.  
    **Fix:** Keep one target only if the contract explicitly limits the provider claim to normal Review; otherwise select the dedicated lifecycle target in a later Build.

13. **Blocking — the one-Build scope is unusually large and requires catalog churn.**  
    **Evidence:** The contract names roughly 48 unique affected paths and requires new tests plus reliability-catalog updates ([INTENT.md:326-343](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:326)); the catalog gate requires exhaustive declarations and source hashes ([test/kogen/test_reliability_catalog_test.exs:15-19](/private/tmp/claude-501/kogen-shape-isolated-candidate-workspace/kogen/test/kogen/test_reliability_catalog_test.exs:15)).  
    **Why:** Workspace admission/publication, root plumbing, both harnesses, credential binding, commands, four new tests, and catalog maintenance are likely beyond one Developer conversation and create high `source_sha256` failure risk.  
    **Fix:** Split admission/publication from harness credential isolation, or pre-shape the exact catalog/remediation updates and reduce the guarded/test surface.

**Overall verdict:** **Not ready for one Build.** The hook-tampering scenario, Codex scope invariant, publication/removal contradictions, missing shaping provenance, and weak/nonexistent proof selectors must be corrected before approval/build admission.