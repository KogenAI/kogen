# Expose unexercised protected acceptance steps

Slug: protected-harness-readiness
Model: not applicable — report projection, evidence completeness validation and diagnostic output add no new workflow or recovery state
Acceptance:
- .kogen/intents/protected-harness-readiness/acceptance.feature
- features/steps/protected_harness_readiness_steps.js
- features/steps/go_driver_support.js
- features/steps/protected_harness_readiness_controls.json

Make readiness's blind spots concrete before protected acceptance is approved: retain and display defined Gherkin steps that Cucumber actually reported SKIPPED in an otherwise complete failed scenario. Preserve accounted missing-feature red. This improves evidence and investigation, not automatic proof that a harness is correct or automatic rejection of a fixture.

Current Go already has clean Snapshot-based readiness, separate undefined/ambiguous binding checks, failed-step/hook feedback to Shape/Refine, declared final-byte good/bad observer controls, and protected-blocker recovery. Keep these. The observed remaining gap is that downstream skipped steps disappear from recorded execution observations; a static step inventory is not evidence of execution.

## Decisions
- Select the smallest remaining native-Go harness readiness improvement, not duplicate delivered recovery, approval or Refine-navigation features. (source: request)
- Keep protected contracts immutable during Build, ordinary implementation failures in repair, and substantive corrections behind Refine and fresh exact approval. (source: request)
- Exclude check-time/reuse, parallel gates, context/review redesign and production adoption of benchmark proposals; preserve external Go authorship and separate Opus/research/Studio ownership. (source: request)

## Source comparison
- addressed: current post-Go selection and original demand for thorough working delivery, source Request/current selection and pipeline-thoroughness; contract outcome, Tests and three acceptance scenarios expose a specific untested part of readiness without claiming semantic proof. Native provenance retains the complete original request/Q&A; this mapping does not replace it.
- addressed as evidence, not a proven Go engine defect: Studio native95ca994e on frozen828dfa5d, baseline985ce348 Git diff/ls-files/show exit128 in finish verification, corrected by Refine50e5a32e, Build3 healthy. Contract history scenario seeds its own actual SHA, observes all three commands succeeding in the source checkout, then early red masking them, later actual 128 statuses in Go clean readiness, and a passing history-independent correction. No Studio file/import, invented historical object, or claim of a new readiness/finish environment discrepancy.
- addressed/reused: KOGEN050's 15/61 is historical corpus evidence, not Go prevalence. Current SHP-8/readiness, observer controls, candidate/build_blocked and intent recover already cover much historical desired behavior; keep existing tests and recovery → independent Refine → new exact approval → fresh production-clean Build with context.md → full verification/fresh Review. No recovery implementation is requested here.
- omitted deliberately: KOGEN050's proposed brittle-pattern linter and exception-based fixture classification are proposals, not settled authority or semantic proof. Report actual skipped execution; neither diagnose skipped code nor execute it out of sequence.
- superseded priority holds: caching828dfa5d and Go d0bc4af0 are installed/qualified per current task state. Never resume old cache/migration operations. Historical caching, elapsed-time, same-input-reuse and broad context/review requests remain retained but implementation belongs to separately assigned lanes.
- addressed boundaries: E2b raw ledger not confirmed; E2c compact ledger exploratory reused-state screen only. No architecture adoption, paid sweep/retry, budget increase, generic critic, weaker gate, Studio change or orchestration subsystem. Preserve Kogen feature-level and Studio higher-product ownership. These local tests claim neither live provider qualification nor release installation.

## Tests
- Complete final Cucumber attempts retain only actually skipped Gherkin steps, including Backgrounds and expanded Outline texts in execution order, excluding hooks and passed/failed steps: add Account regressions, retain binding/incomplete/duplicate/retry tests (regression)
- Failure diagnostics expose skipped-step count/location/text and uncertainty to the card, Shape acknowledgment and original/candidate Refine observations: CLI scenarios below and focused Shape/Refine feedback regressions (scenario)
- Complete reports without skipped steps retain [] and emit no skipped-step notice; warnings do not classify failures or change authority: corrected history and mixed Outline scenarios (integration)
- Retained evidence round-trips the observations; absent/invalid new metadata is an ordinary miss, never silently zero skipped: scenarios check missing-field re-execution and exact retention; add focused malformed-field cache tests (integration)
- Early red can mask a history assumption that later fails in clean readiness and passes after explicit fixture correction: installed-CLI history regression with real source-success controls and execution traces (regression)
- Existing readiness, clean scratch and protected blocker recovery retain authority and behavior: existing cli/verify, cli/shape and cli/build tests including recovery coverage (existing)

## Contract

Extend ScenarioResult in acceptance accounting and retained readiness with `unexercised_steps`. For a complete uniquely matched final attempt this is an array of existing StepRecord-shaped objects with exactly `keyword`, `text`, `line`. Preserve keyword spelling/trailing space and AST source line; use expanded Pickle text per Examples row. Include only Gherkin steps whose actual final `testStepFinished.testStepResult.status` is SKIPPED, in test-case step order, including Backgrounds. Exclude hooks and retried attempts as existing accounting does. Do not infer the list from the first failure, scenario status or static remainder. Complete execution with none has `[]`, not null/absence. Missing, invalid or nonunique accounting retains unknown (`null`), not invented proof of zero; existing accounting failures still refuse readiness.

Keep scenario status, failure details, binding checks, pass/fail accounting and eligibility unchanged. Defined skipped tails after failed assertions remain allowed at readiness. Undefined, ambiguous, pending, whole-scenario skipped, missing, duplicate, unfinished and unexpected executions retain their existing gates. This is observation, not a coverage guarantee or exception classifier.

Retain arrays in `.kogen/local/readiness/<slug>.json`, cached Ready, Shape/Refine observations and Refine original/candidate records. Keep version 3 and existing baseline/hash/HEAD/Snapshot identity checks. For otherwise eligible passed/failed records, absent/null/non-array observations or structurally invalid objects (wrong types, nonexistent/mismatched scenario step, duplicate or wrong source execution order) are normal misses with fresh ordinary readiness. No migration/default-to-empty. Valid complete metadata reuses existing evidence, including skipped arrays. This is schema completeness, not new check-result reuse or broader caching.

When any Gherkin steps were skipped, the shared bounded observations used by the card, Shape acknowledgment and Refine original/candidate feedback include:
- `Unexercised acceptance steps: <N>` counting instances across scenario/Examples results, without row deduplication.
- Exactly `Skipped steps are unexercised; readiness does not prove their behavior or fixture validity.`
- Per-scenario identification including Examples-row line, and each skipped step on a line whose trimmed contents are `acceptance.feature line <line>: <trimmed keyword> <expanded text>`.

Keep actual first failure/hook detail, exit, baseline/hash/HEAD and evidence reference. Put summary/notice before potentially long failure details. Preserve UTF-8-safe 16 KiB bounds and explicit omission markers; complete arrays remain in evidence. No summary/notice when all arrays are empty. Never call a skipped assertion passed, validated or defective.

Update applicable SHP-8 prose and native Shape/Refine investigation guidance to distinguish executed failures from unexercised tails and use focused good/bad controls for risky masked protected assertions. No mandatory whole-suite probe, critic, lint-as-proof, paid retry, new rejection, out-of-sequence step execution or engineering question. Concisely update README's readiness limitation/evidence description.

No builder authorization is added. Ordinary implementation errors stay in repair; protected contradictions remain builder-reported and unproven. Preserve existing `kogen intent recover <build-id> --output <new-external-directory>`: preserve production, clear only recorded delta, investigate correction.md independently through normal Refine using ORIGINAL full contract hash, revoke old approval only on success, require fresh exact approval and production-clean fresh Build with context.md, full normal checks/model/acceptance, fresh independent Review and final-tree verification. No automatic import/resume, old-green reuse or approval transfer. Read-only context/inspect observes long work; no polling/retry. Do not reimplement this delivered flow.

## Feasibility
- Local toolchain probe found Go, Node and installed local Cucumber, and confirmed exploratory copies omit original Git history (exit 0, 0.0 s).
- Focused local installed-Go history probe observed source statuses [0,0,0], zero history execution under early missing-feature red, clean-readiness [128,128,128] once reached, and a passing history-independent correction. Current skipped observations/notice were absent; exact repeated cards reused evidence, and deleting the absent new field did not rerun readiness. This proves the diagnostic gap, not a finish engine defect (exit 0, 21.7 s). Final assertions use semantic object equality instead of the exploratory comparison.
- Focused Outline fixture diagnostic after readiness exposed a callback-arity error in the generated fixture: parameterized Then callbacks accepted zero arguments. The probe reached both actual row failures and confirmed this was fixture error, not product red (exit 0, 19.9 s). Corrected both callbacks; subsequent native readiness observes first-row failed/second-row passed, with remaining mismatches confined to the requested observations and metadata completeness. This does not claim every future fixture is correct.
- Documentation discovery in this Shape found official Cucumber among noisy results. Fetch https://cucumber.io/ returned retrieved untrusted HTML; https://cucumber.io/docs/cucumber/api/ returned truncated untrusted HTML, not complete protocol evidence; https://raw.githubusercontent.com/cucumber/messages/main/messages.md returned unsupported. Pinned local Cucumber/Go Account source and actual execution ground this change; no network behavior changes or exhaustive documentation claim.
- evidence: {"id":"report-observer","kind":"observer","inputs":[".kogen/intents/protected-harness-readiness/acceptance.feature","features/steps/protected_harness_readiness_controls.json","features/steps/go_driver_support.js"],"observers":["features/steps/protected_harness_readiness_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/protected_harness_readiness_steps.js --control good","exit":0,"output":"observer accepts known-good reports\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/protected_harness_readiness_steps.js --control bad","exit":1,"output":"observer rejects independently corrupted reports\n"}]}
