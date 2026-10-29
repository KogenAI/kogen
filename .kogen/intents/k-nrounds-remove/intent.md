# Remove native per-round request limits

Slug: k-nrounds-remove
Model: not applicable — removes an unused opt-in limit; the existing Build budget state machine is unchanged
Acceptance:
- .kogen/intents/k-nrounds-remove/acceptance.feature
- features/steps/k_nrounds_remove_steps.js

Remove NativeRoundLimits from Build Deps, ShapeInput and RefineInput, its MaxRounds assignment, native_round_limit outcome/event handling, and its tests and docs. Remove the obsolete k-nrounds acceptance package and exclusively owned step file. Update historical budget prose referencing the option without changing budget behavior or tests. No live references to the removed option remain, except this removal contract and acceptance. Do not rewrite private historical provenance.

Defaults remain byte-identical apart from already nondeterministic IDs/timestamps. Default fake-provider Build requests, records and landing remain unchanged. Preserve K-BUILDBUDGET behavior and tests, whole-Build counting across passes/resume, zero/off and Review exclusion. Preserve Claude Code max_rounds and CLI behavior. Build and all configured checks must pass.

## Decisions
- Delete rather than merge: budget accounting already uses attemptRequester independently; retain shared request/loop plumbing and remove only cap-specific plumbing (source: request)
- Keep the protected pinned loop's generic MaxRounds capability untouched; remove only Kogen's option and special handling (source: request)
- No CLI or configuration changes; Claude Code max_rounds remains separate (source: request)
- Local fake providers and temporary directories only; never stop processes by name/pattern, terminate only started PIDs, and generate no synthetic CPU load (source: request)

## Source comparison
- Addressed: What to change maps to removal of fields, assignment, outcome/event, tests and docs above; Decisions settles deletion versus merge preserving shared budget plumbing.
- Addressed: Must stay and Acceptance map to unchanged defaults, budget behavior/tests, default fake Builds, executor max_rounds, CLI and all configured checks. Executable acceptance scans production references and runs existing affected packages; configured verification supplies the remaining gates.
- Addressed: Host safety maps to local-only temporary-directory execution restrictions.
- Superseded: the obsolete k-nrounds contract and tests are removed rather than retained as runnable acceptance. Budget documentation changes do not change budget tests.
- Omitted from implementation scope: Main F8 (29 Oct 2026), commits 31c745e and e6ca919, witness lb-dry, FINDINGS row loop-round-limit-step0 and research loop-bounds climb are motivation, not new research runs. The reported approximately four requests per pass is not remeasured.
- No conflicting requested behavior identified. Protected vendored generic engine and private historical evidence remain unchanged, not a remaining Kogen option.

## Tests
- Removed option and event/outcome disappear: scan cli Go files outside third_party for removed identifiers (regression)
- Default fake-provider Builds remain unchanged: retain existing Build landing, record and default tests unchanged (existing)
- Budget behavior and tests remain unchanged: run unchanged TestBuildRequestBudgetAcrossPasses, TestBuildRequestBudgetResume, TestBuildRequestBudgetOff and TestBuildRequestBudgetReview with the build package (existing)
- Shape/Refine and executor behavior stays unchanged: run existing affected package tests, deleting only removed-option tests (existing)
- Build and all configured checks pass: configured format, compile, go-test, spec and building chapter Cucumber checks (existing)

## Feasibility
- none
