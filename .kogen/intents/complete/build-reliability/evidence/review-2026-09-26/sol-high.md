## Blocking

1. **`controller-runs-prepare-before-paid` / `self-hosting-accounting` — promised behavior is not exercised by this Build.**  
   The scenario says the controller runs each selected target’s `prepare` before paid dispatch (`scenarios.yaml:290-317`), and `INTENT.md` presents that as the Build’s starting behavior (`INTENT.md:42-53`). But the risk explicitly says this Build runs main’s old controller, which ignores `prepare`; the behavior only takes effect in later Builds or nested fixture Builds (`risks.yaml:15-29`). Main’s `CatalogChange` preserves admission entries for existing targets (`lib/kogen/build/catalog_change.ex:5-14, 62-69`), so the current Build’s `live-reviewer-rework` execution cannot prove the stated controller behavior.  
   **Minimal fix:** scope the scenario and outcome explicitly to the nested/future controller, or add a required nested Build proof and stop claiming this outer Build verifies it.

2. **`helper-make-targets-allowed` / `self-hosting-relaxations` — the relaxation is only fixture-proven while main still rejects a Candidate helper target.**  
   Main invokes its loaded `VerificationPlan.load` against the Candidate every cycle (`lib/kogen/build/catalog_change.ex:23-47`). At 7ed41f660 that loader still requires exact Makefile/catalog equality (`lib/kogen/build/verification_plan.ex:264-277`). The Draft correctly warns that this Candidate must not add a non-catalog target (`risks.yaml:142-156`), but the scenario’s product claim says other Make targets are allowed (`scenarios.yaml:1531-1557`). A Build can therefore pass while the promised repository-level relaxation remains untested and unavailable under the controller that actually runs it.  
   **Minimal fix:** state this is fixture-only and deferred until a controller-updating Intent, or make a nested Candidate Build the acceptance proof.

3. **`test-catalog-binds-declarations` — current Build self-hosting boundary is under-specified.**  
   The Candidate removes `source_sha256` and changes catalog validation (`scenarios.yaml:1303-1339`), while main’s loaded `offline.py` and test process still run Candidate files. This is probably safe, but the Draft does not explicitly prove the current controller’s receipt binding remains compatible with the changed catalog; `offline.py` records the catalog digest (`scripts/check/offline.py:158-170`).  
   **Minimal fix:** require a Candidate `check` assertion that receipt `catalog_sha256` remains the digest of the revised catalog and that no consumer still expects `source_sha256`.

## Guarded paths

None found. All listed `affected_paths` match `may_change_guarded_paths` in `intent.yaml:53-87`; no scenario requires editing `.gitignore`, hook registrations, or an unselected live owner. The `.gitignore` behavior itself is correctly identified as frozen by `GuardedPaths.same_config` (`lib/kogen/build/guarded_paths.ex:33-67`).

## Contradictions

The main contradiction is the prepare/self-hosting pair above. Q2’s two paid targets is internally consistent with the later superseding decision in `questions.md:19-30`, though it should be carried into the final approval record.

## Proof

No definite `proof.base` defect found. The report’s seven stale declarations are reproducible: a direct source-name scan finds exactly seven unresolved rows, and `discover/1`/`exunit_declarations/1` have no callers (`test/support/test_reliability_catalog.ex:58-63,168-179`). Rank ordering is correctly at `verification_plan.ex:497-500`, not the previously reported nonexistent line.

## Factual evidence

The report’s claims about the seven stale rows, ignored unknown config keys (`lib/kogen/intent.ex:83-100`), and exact Makefile/catalog equality (`lib/kogen/build/verification_plan.ex:264-277`) match source bytes at 7ed41f660.

## Appetite

Non-blocking concern: 28 scenarios plus `check` (reported 185–271 seconds) and two paid targets is a high-risk single conversation. `process-custody-teardown`, `reviewer-reask-once`, and `shaping-smoke-target` have the largest operational and provider-failure surface. The Shaper’s explicit one-Intent decision is the remaining human choice.
