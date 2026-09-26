1. **Blocking — Proof selectors do not exist.**  
   Evidence: [scenarios.yaml:43](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:43), [scenarios.yaml:92](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:92), [scenarios.yaml:138](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:138), [scenarios.yaml:171](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:171), [scenarios.yaml:208](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:208), [scenarios.yaml:361](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:361).  
   `test/kogen/build_workspace_test.exs`, `test/kogen/harness_home_test.exs`, `test/kogen/candidate_verification_test.exs`, and `test/kogen/candidates_command_test.exs` are absent. `VerificationPlan.valid_selector?/4` requires an existing or affected planned selector and a supported test source ([verification_plan.ex:219-245](lib/kogen/build/verification_plan.ex:219)).  
   **Fix:** Add the maintained test files before approval, or replace selectors with existing focused tests and add their actual affected paths.

2. **Blocking — The package cannot currently satisfy its own test-catalog contract.**  
   Evidence: [scripts/check/README.md:166-171](scripts/check/README.md:166), [intent.yaml:104](.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:104).  
   The proposed implementation edits many existing `test/kogen/**` and `test/support/**` files, but the package does not identify the required `test-reliability.yaml` declarations/source-hash refresh as a scenario effect. Any edited cataloged test leaves `source_sha256` stale and makes `make check` fail.  
   **Fix:** Enumerate catalog updates in affected paths and require the refresh/check step, or use new maintained selectors with catalog entries.

3. **Blocking — A plausible wrong implementation can pass the named proofs while violating routing.**  
   Evidence: [scenarios.yaml:108-127](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:108), [scenarios.yaml:138-143](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:138).  
   An implementation can set the Developer cwd to the Candidate, but leave controller verification, report generation, Jev, or Reviewer root resolution on the control checkout. Fake-harness environment assertions can still pass if they only inspect launch metadata, while `File.cwd!()` defaults in adapters and report/evidence code continue reading control ([lib/kogen/claude_code.ex:40](lib/kogen/claude_code.ex:40), [lib/kogen/codex.ex:22](lib/kogen/codex.ex:22), [lib/kogen/build/evidence.ex:11](lib/kogen/build/evidence.ex:11)).  
   **Fix:** Add a real three-root integration control that places distinct sentinels in control, Candidate, and controller cwd, then asserts every listed operation’s actual reads/writes and Git toplevel.

4. **Blocking — Claude credential sanitization is underspecified and incomplete.**  
   Evidence: [scenarios.yaml:52-75](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:52), [lib/kogen/claude_code.ex:21-24](lib/kogen/claude_code.ex:21), [lib/kogen/claude_code.ex:79-95](lib/kogen/claude_code.ex:79).  
   The scenario supplies `OPENAI_API_KEY` and requires inherited credentials to be gone, but Claude’s current sanitizer removes `ANTHROPIC_*` and Claude variables only; it does not remove `OPENAI_*`, and it does not currently remove `CLAUDE_SECURESTORAGE_CONFIG_DIR`. A wrong implementation can therefore leak an inherited API key or select the personal login.  
   **Fix:** Define the complete blocked environment set, explicitly remove `CLAUDE_SECURESTORAGE_CONFIG_DIR`, `OPENAI_*`, and the listed token variables, set the intended value afterward, and assert all of them in a real child-process environment test.

5. **Advisory — Codex isolation is only partial and conflicts with the “harness home per Build” wording.**  
   Evidence: [INTENT.md:91-94](.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:91), [lib/kogen/codex/environment.ex:84-95](lib/kogen/codex/environment.ex:84).  
   `CODEX_HOME` remains the shared scope, so `auth.json` and rollouts remain shared across Builds. The per-Build operation root isolates HOME/XDG/sqlite, but shared rollouts/session state can still leak metadata or collide.  
   **Fix:** Narrow the contract to “per-Build operation state with shared credential scope,” and add explicit assertions that shared Codex files are intentionally retained and never treated as per-Build evidence.

6. **Blocking — Guarded paths are too broad for self-hosting.**  
   Evidence: [intent.yaml:104-127](.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:104), [risks.yaml:3-17](.kogen/intents/drafts/isolated-candidate-workspace/risks.yaml:3), [lib/kogen/verification_policy.ex:11-14](lib/kogen/verification_policy.ex:11).  
   `lib/kogen/verification_policy.ex`, all of `lib/kogen/build/**`, and all `test/support/**` are writable by the Candidate even though the then-main controller reads policy, prompts, catalog, and engine modules from control. A Developer change to policy or lazily loaded controller code can affect the installing Build or cause the exact self-hosting failure described in the risk.  
   **Fix:** Exclude controller-owned policy/engine files from Candidate guards unless a specific child-process boundary proves they are loaded only from Candidate; split broad globs into exact implementation files.

7. **Advisory — The selected paid target is compliant, but its observation is narrower than the scenario.**  
   Evidence: [questions.md:45-53](.kogen/intents/drafts/isolated-candidate-workspace/questions.md:45), [scenarios.yaml:82-100](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:82).  
   One distinct target, `live-shape-to-build`, satisfies D8 and the ROADMAP “one lifecycle target” rule. Leaving `live-reviewer-rework` and `live-general` unrun is acceptable because they are not edited and the selected lifecycle fixture already contains Reviewer/rework coverage. However, the paid evidence only explicitly checks the Claude Developer transcript and binding; it does not independently establish every Reviewer/Codex routing claim.  
   **Fix:** State exactly which lifecycle facts the paid target owns and rely on explicit offline controls for the remaining roles, or add those observations to the paid fixture without selecting another target.

8. **Advisory — Scope exceeds the stated ROADMAP outcome in places.**  
   Evidence: [INTENT.md:3](.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:3), [intent.yaml:104-127](.kogen/intents/drafts/isolated-candidate-workspace/intent.yaml:104).  
   Candidate list/remove commands, extensive publication/retention machinery, runtime-upgrade workflow edits, broad root-profile audits, and Codex state changes go beyond the concise row-5 outcome unless each is required for “a worktree, harness home and credentials per Build; Shaping keeps working.”  
   **Fix:** Mark each extra feature as a necessary acceptance mechanism with a scenario, or defer it to a separate Intent.

9. **Blocking — One-Build reliability is poor as written.**  
   Evidence: [INTENT.md:53-81](.kogen/intents/drafts/isolated-candidate-workspace/INTENT.md:53), [scenarios.yaml:7-366](.kogen/intents/drafts/isolated-candidate-workspace/scenarios.yaml:7), [scripts/check/README.md:166-171](scripts/check/README.md:166).  
   Eleven scenarios, many new tests, missing selectors, catalog hash churn, real Git/worktree lifecycle, Keychain-dependent paid execution, and self-hosting constraints create several independent failure points. The package also says the Build compiles cold and copies only `deps/`, increasing setup sensitivity.  
   **Fix:** Reduce the first Build to the minimum lifecycle slice, add all selectors and catalog declarations before admission, keep the existing paid fixture unchanged except for the required harness assertions, and split candidate commands/publication retention into a follow-up if they are not essential.

**Overall verdict:** **Reject as not Build-ready.** The nonexistent proof selectors and unaccounted test-catalog updates are immediate blockers; the self-hosting guard breadth and incomplete credential sanitization create additional correctness and security risk.