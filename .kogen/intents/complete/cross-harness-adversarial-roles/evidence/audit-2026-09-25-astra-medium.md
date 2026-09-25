1. **Blocking — D8 violation and unverified live owners.**  
   Evidence: `INTENT.md:110-115` explicitly says `live_test.exs` and `live_shape_to_build_test.exs` are edited but not run; `scenarios.yaml:163-203` gives `default-route-live-consumers` only `[check]`, with offline selectors that do not execute either live owner. The Makefile defines separate paid targets for both (`Makefile:8-18`).  
   Fix: add the edited targets to `verified_by`/`paid_target` as required by D8, or remove those edits from this Intent and defer them completely to the consuming Intent.

2. **Blocking — Proof selectors cannot observe the stated `then`.**  
   Evidence: `scenarios.yaml:173-179` requires exact role-aware assertions and preservation of live-owner assertions, but its proof is only `test/kogen/root_profile_audit_test.exs` and `test/kogen/configuration_support_contract_test.exs` (`scenarios.yaml:189-203`). A Candidate can delete the assertions in `live_test.exs` and `live_shape_to_build_test.exs`, leave them compiling, and pass every named proof while violating the outcome.  
   Fix: make the selectors execute the affected owner tests, or add offline tests that read and assert the required live-owner source/contracts directly; retain an explicit assertion-preservation check.

3. **Blocking — The default-route scenario’s paid proof is internally contradictory.**  
   Evidence: the scenario says the default change moves Reviewer behavior in `live-general` and `live-shape-to-build` (`scenarios.yaml:165-178`), but declares `paid_target: none` (`scenarios.yaml:196-203`). D8 and the catalog identify both as provider-backed targets (`Makefile:8-18`, `verification_targets.yaml:18-23,93-99`).  
   Fix: assign the corresponding narrow paid target(s), or split the scenario so this Intent does not claim to verify live behavior it intentionally does not run.

4. **Blocking — Required affected paths are not fully represented in scenario proofs.**  
   Evidence: the Intent requires every Codex root launch to retain the central output limit (`INTENT.md:44-53`), and the implementation owner is `lib/kogen/codex/environment.ex` (`scenarios.yaml:89`), but the affected paths omit its direct contract tests such as `test/kogen/codex_environment_test.exs` and `test/kogen/harness_args_test.exs` (see those files’ launch-argument assertions at lines 1-45).  
   Fix: add every launch/environment contract test the Developer must update to `affected_paths` and to the relevant offline proof; state that only ledger `source_sha256` values may change.

5. **Advisory — Dependency #1 leaves a stale live-owner contract outside this Intent’s declared paths.**  
   Evidence: this Intent relies on an external fixture root (`INTENT.md:39-46`), while the current `test/kogen/live_reviewer_rework_test.exs:29-32` documents and configures the fixture under `.kogen/runtime/`. The role-boundary scenario’s affected paths omit `test/kogen/live_reviewer_rework_test.exs` (`scenarios.yaml:123-131`).  
   Fix: either include that owner in `affected_paths` and specify the required documentation/setup update, or explicitly state that Intent #1 owns and must update it before this Build, with a validation dependency.

6. **Advisory — Runtime acceptance can force a mid-Build `cannot_comply` with no permitted remediation.**  
   Evidence: the scenario requires two fresh Codex Reviews to complete within the unchanged 1,200,000 ms timeout (`scenarios.yaml:105-111`), while the risk records Codex Reviewer duration as unmeasured and says a timeout returns the Intent to Shaping (`risks.yaml:22-42`). The package simultaneously forbids raising timeouts or reducing Reviewer effort (`INTENT.md:153-156,197`).  
   Fix: define a deterministic pre-Build readiness/performance gate using the post-#1 fixture, or make the acceptance condition provider-observation-based with an explicit bounded failure disposition that does not require the Developer to object mid-Build.

7. **Advisory — Compatibility retry semantics do not account for the main controller’s repeated paid cycles.**  
   Evidence: the Intent permits a whole fresh-fixture retry after `timed_out` (`INTENT.md:85-93`; `scenarios.yaml:215-229`), while the supplied controller context says Stop reruns every selected paid target each cycle. The package only constrains the inner test’s 15-minute ExUnit window and does not state how repeated Stop cycles interact with the “one rerun” guarantee.  
   Fix: specify that the one retry is per target invocation and that controller-level cycles remain governed by the frozen Stop policy, with evidence retained across cycles and no additional owner-level retries.