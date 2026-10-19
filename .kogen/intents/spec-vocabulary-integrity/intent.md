# Restore specification vocabulary integrity

Slug: spec-vocabulary-integrity
Model: not applicable — this is static vocabulary/check consistency maintenance with no new state or transitions
Acceptance:
- .kogen/intents/spec-vocabulary-integrity/acceptance.feature
- features/steps/spec_vocabulary_integrity_steps.js

Repair the unused vocabulary declaration that prevents the original complete `(cd spec && sh check.sh)` from passing on signed baseline `f3150d0f05eab679cc07d8a7b04a3284edaa63cc`. The reported pattern is `^the\ file\ "([^"]*)"\ has\ (\d+)\ lines?$` in `spec/features/STEPS.md`. Inspection finds no file-line-count sentence in the maintained scenarios; `spec/tools/check.mjs` directly matches compiled step text against the declared regular expressions and rejects unused patterns. Retire only this obsolete declaration once the actual wrapper diagnostic confirms it. Do not rewrite the matcher without demonstrated evidence of a matching defect; such a repair would require a meaningful existing negative check.

Retain every current public scenario and requirement (146 scenarios, 102 requirements), unchanged. Do not add a dummy scenario merely to consume the pattern. Keep `spec/check.sh` and `spec/tools/check.mjs` unchanged: no weakened unused-step lint, exclusions, phase skipping, wrapper narrowing or configured command changes. All existing model typecheck, test, Safety and non-vacuity phases must genuinely run and pass; a later failure is not success and must not be hidden.

Limit implementation to specification vocabulary consistency and the small owned Intent/acceptance/helper artifacts. No production logic, runtime documentation/instructions, packaging, dependency/toolchain inputs, configuration, model roles/defaults or worker settings changes. Declared setup supplies the spec dependencies; acceptance runs the real wrapper with inherited environment, not substituted tools or mocked output.

Delivery remains native exact-full-hash caller approval, Build, one independent reviewer/fixer, final verification and signed logical commit. Preserve serial Sol6.1high shaping, medium building and high review; no optional worker dispatch or new critic. Preserve prior failures and costs, including external evidence at `../spec-vocabulary-integrity-20261020/prior-failure`; do not repeat a baseline archive audit or edit external sources/generated contracts. Before completion, the full original wrapper must pass on the exact final source alongside configured native verification. After signing, compare ALL actual package/runtime input files with retained signed f315. If only spec/Intent/helper/test files changed and packaged inputs are identical, prefer source-only binding to the actual retained f315 prefix/archive; do not rebuild, version-stamp or replace the global runtime solely for this maintenance. This does not waive declared setup or verification. If package inputs changed, report that fact for ordinary exact-package qualification, not an identity claim. The repository remains unreleased; root alone handles the ledger and normal push.

## Decisions
- Retire only a proven obsolete vocabulary declaration, retaining all current public behavior and the original complete checker. (source: request)
- Use one executable acceptance running the full wrapper, with no new Quint model or implementation-mirroring tests. (source: request)
- Keep delivery source-only when all actual packaged inputs remain identical to retained signed f315. (source: request)

## Tests
- The original full specification wrapper passes with all 146 scenarios and 102 requirements retained and all existing model phases enabled: add one regression scenario invoking `sh check.sh` in `spec/`, asserting exit 0, the original wrapper digest, coverage summary, model phase markers and final success; report its actual diagnostic on failure (regression)

## Feasibility
- none
