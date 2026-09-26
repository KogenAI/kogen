READ-ONLY AUDIT. Do not modify, create or delete any file anywhere. Do not run git commands that write, mix compile/test, or make. Only read files.

Re-audit the Kogen Intent package `.kogen/intents/drafts/isolated-candidate-workspace/` in the current directory (Kogen clone at main 2909f557). A previous audit by you found the issues listed below; the package was revised. For EACH numbered previous finding, say FIXED or NOT FIXED with file:line evidence. Then list any NEW blocking issue introduced or still present (infeasible/contradictory scenario, wrong implementation passing the proofs, missing guarded path, conflict with the then-main controller under self-hosting D9, paid-target misuse). Context as before: fortify-paid-verification (.kogen/intents/approved/fortify-paid-verification/) has landed (controller-owned verification), plus bounded-reviewer-evidence, cross-harness-adversarial-roles, shaping-preflight-audit. The package is intentionally status draft with a recorded approval block; the driver moves it to approved/ later (not a finding). Proof selectors may be new files the Developer creates if listed in the scenario's affected_paths (VerificationPlan accepts that); judge whether the scenario text now requires meaningful tests.

Previous findings:
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
ASTRA: 1. **Blocking — Proof selectors do not exist.**  
ASTRA:    Evidence: [scenarios.yaml:43](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:43), [scenarios.yaml:92](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:92), [scenarios.yaml:138](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:138), [scenarios.yaml:171](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:171), [scenarios.yaml:208](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:208), [scenarios.yaml:361](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:361).  
ASTRA:    `test/kogen/build_workspace_test.exs`, `test/kogen/harness_home_test.exs`, `test/kogen/candidate_verification_test.exs`, and `test/kogen/candidates_command_test.exs` are absent. `VerificationPlan.valid_selector?/4` requires an existing or affected planned selector and a supported test source ([verification_plan.ex:219-245](lib/kogen/build/verification_plan.ex:219)).  
ASTRA:    **Fix:** Add the maintained test files before approval, or replace selectors with existing focused tests and add their actual affected paths.
ASTRA: 
ASTRA: 2. **Blocking — The package cannot currently satisfy its own test-catalog contract.**  
ASTRA:    Evidence: [scripts/check/README.md:166-171](scripts/check/README.md:166), [intent.yaml:104](.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:104).  
ASTRA:    The proposed implementation edits many existing `test/kogen/**` and `test/support/**` files, but the package does not identify the required `test-reliability.yaml` declarations/source-hash refresh as a scenario effect. Any edited cataloged test leaves `source_sha256` stale and makes `make check` fail.  
ASTRA:    **Fix:** Enumerate catalog updates in affected paths and require the refresh/check step, or use new maintained selectors with catalog entries.
ASTRA: 
ASTRA: 3. **Blocking — A plausible wrong implementation can pass the named proofs while violating routing.**  
ASTRA:    Evidence: [scenarios.yaml:108-127](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:108), [scenarios.yaml:138-143](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:138).  
ASTRA:    An implementation can set the Developer cwd to the Candidate, but leave controller verification, report generation, Jev, or Reviewer root resolution on the control checkout. Fake-harness environment assertions can still pass if they only inspect launch metadata, while `File.cwd!()` defaults in adapters and report/evidence code continue reading control ([lib/kogen/claude_code.ex:40](lib/kogen/claude_code.ex:40), [lib/kogen/codex.ex:22](lib/kogen/codex.ex:22), [lib/kogen/build/evidence.ex:11](lib/kogen/build/evidence.ex:11)).  
ASTRA:    **Fix:** Add a real three-root integration control that places distinct sentinels in control, Candidate, and controller cwd, then asserts every listed operation’s actual reads/writes and Git toplevel.
ASTRA: 
ASTRA: 4. **Blocking — Claude credential sanitization is underspecified and incomplete.**  
ASTRA:    Evidence: [scenarios.yaml:52-75](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:52), [lib/kogen/claude_code.ex:21-24](lib/kogen/claude_code.ex:21), [lib/kogen/claude_code.ex:79-95](lib/kogen/claude_code.ex:79).  
ASTRA:    The scenario supplies `OPENAI_API_KEY` and requires inherited credentials to be gone, but Claude’s current sanitizer removes `ANTHROPIC_*` and Claude variables only; it does not remove `OPENAI_*`, and it does not currently remove `CLAUDE_SECURESTORAGE_CONFIG_DIR`. A wrong implementation can therefore leak an inherited API key or select the personal login.  
ASTRA:    **Fix:** Define the complete blocked environment set, explicitly remove `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `OPENAI_*`, and the listed token variables, set the intended value afterward, and assert all of them in a real child-process environment test.
ASTRA: 
ASTRA: 5. **Advisory — Codex isolation is only partial and conflicts with the “harness home per Build” wording.**  
ASTRA:    Evidence: [INTENT.md:91-94](.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:91), [lib/kogen/codex/environment.ex:84-95](lib/kogen/codex/environment.ex:84).  
ASTRA:    `CODEX_HOME` remains the shared scope, so `auth.json` and rollouts remain shared across Builds. The per-Build operation root isolates HOME/XDG/sqlite, but shared rollouts/session state can still leak metadata or collide.  
ASTRA:    **Fix:** Narrow the contract to “per-Build operation state with shared credential scope,” and add explicit assertions that shared Codex files are intentionally retained and never treated as per-Build evidence.
ASTRA: 
ASTRA: 6. **Blocking — Guarded paths are too broad for self-hosting.**  
ASTRA:    Evidence: [intent.yaml:104-127](.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:104), [risks.yaml:3-17](.kogen/intents/drafts/isolated-candidate-workspace/risks.yaml:3), [lib/kogen/verification_policy.ex:11-14](lib/kogen/verification_policy.ex:11).  
ASTRA:    `lib/kogen/verification_policy.ex`, all of `lib/kogen/build/**`, and all `test/support/**` are writable by the Candidate even though the then-main controller reads policy, prompts, catalog, and engine modules from control. A Developer change to policy or lazily loaded controller code can affect the installing Build or cause the exact self-hosting failure described in the risk.  
ASTRA:    **Fix:** Exclude controller-owned policy/engine files from Candidate guards unless a specific child-process boundary proves they are loaded only from Candidate; split broad globs into exact implementation files.
ASTRA: 
ASTRA: 7. **Advisory — The selected paid target is compliant, but its observation is narrower than the scenario.**  
ASTRA:    Evidence: [questions.md:45-53](.kogen/intents/drafts/isolated-candidate-workspace/questions.md:45), [scenarios.yaml:82-100](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:82).  
ASTRA:    One distinct target, `live-shape-to-build`, satisfies D8 and the ROADMAP “one lifecycle target” rule. Leaving `live-reviewer-rework` and `live-general` unrun is acceptable because they are not edited and the selected lifecycle fixture already contains Reviewer/rework coverage. However, the paid evidence only explicitly checks the Claude Developer transcript and binding; it does not independently establish every Reviewer/Codex routing claim.  
ASTRA:    **Fix:** State exactly which lifecycle facts the paid target owns and rely on explicit offline controls for the remaining roles, or add those observations to the paid fixture without selecting another target.
ASTRA: 
ASTRA: 8. **Advisory — Scope exceeds the stated ROADMAP outcome in places.**  
ASTRA:    Evidence: [INTENT.md:3](.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:3), [intent.yaml:104-127](.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:104).  
ASTRA:    Candidate list/remove commands, extensive publication/retention machinery, runtime-upgrade workflow edits, broad root-profile audits, and Codex state changes go beyond the concise row-5 outcome unless each is required for “a worktree, harness home and credentials per Build; Shaping keeps working.”  
ASTRA:    **Fix:** Mark each extra feature as a necessary acceptance mechanism with a scenario, or defer it to a separate Intent.
ASTRA: 
ASTRA: 9. **Blocking — One-Build reliability is poor as written.**  
ASTRA:    Evidence: [INTENT.md:53-81](.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:53), [scenarios.yaml:7-366](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:7), [scripts/check/README.md:166-171](scripts/check/README.md:166).  
ASTRA:    Eleven scenarios, many new tests, missing selectors, catalog hash churn, real Git/worktree lifecycle, Keychain-dependent paid execution, and self-hosting constraints create several independent failure points. The package also says the Build compiles cold and copies only `deps/`, increasing setup sensitivity.  
ASTRA:    **Fix:** Reduce the first Build to the minimum lifecycle slice, add all selectors and catalog declarations before admission, keep the existing paid fixture unchanged except for the required harness assertions, and split candidate commands/publication retention into a follow-up if they are not essential.
ASTRA: 
ASTRA: **Overall verdict:** **Reject as not Build-ready.** The nonexistent proof selectors and unaccounted test-catalog updates are immediate blockers; the self-hosting guard breadth and incomplete credential sanitization create additional correctness and security risk.

Output: per-finding FIXED/NOT FIXED list (sol-1..13 and astra-1..9), then NEW blocking issues (or "none"), then a one-line verdict. Concise.
