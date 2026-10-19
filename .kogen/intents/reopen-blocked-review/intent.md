# Reopen blocked review on explicit resume

Slug: reopen-blocked-review
Model: .kogen/intents/reopen-blocked-review/model.qnt invariants=Safety seed=2033 samples=200 steps=30
Acceptance:
- .kogen/intents/reopen-blocked-review/acceptance.feature
- features/steps/reopen_blocked_review_steps.js

Repair ordinary `kogen intent resume <build-id> [--project <checkout>]` for compatible `candidate/review_blocked` checkpoints. Currently `Review.resume/2` evaluates the saved terminal `changes` verdict again and stops without verification or a provider request. Replace that replay with a candidate-preserving, explicitly requested retry under the saved independent reviewer. Do not restart the builder or create another whole-change critic.

After all existing identity, HEAD, approval, protected baseline/configuration, candidate, index and uncertainty guards, materialize the exact saved candidate and run fresh declared setup and the ordinary complete verification gate (acceptance, Quint when declared, configured checks). Preserve ordinary fail-fast semantics: failures and unrun items are red, not evidence of success. The earlier completed green pass and earlier approval cannot resolve the latest blocker. Return the original blocking finding and actual fresh results, including setup failure/red/unrun results, to the SAME saved independent reviewer conversation for targeted clearance or scoped repair. Do not fabricate an operator explanation. A new `changes` stops normally; explicit `approve` clears the blocker only subject to ordinary external verification of edits and exact final green-tree commit eligibility. An unresolved retry requires another explicit resume, not an automatic loop.

Use established Build/Review/Run/Checks owners; checkpoint the retry's verification and continued conversation so interruption/provider failure resumes at the safe saved owner and evidence boundary, not at terminal-verdict replay. Incomplete verification restarts fresh setup; completed exact retry evidence may survive an interrupted provider request, but never stands in for a new decision. Keep original finding, conversation/tool outputs, stage number, candidate, approval, original-index backup, immutable failed-attempt artifacts, parent/root lineage and honest cumulative known usage/unknown requests. Uncertain executed tools/commits remain refusals. Preserve normal hooks, signing, commit-crash/no-duplicate-commit and index custody.

Compatibility includes real version 2 blocked runs produced by retained signed c3ee2a8e, including saved earlier green/approval followed by failed final verification and latest `changes`. No manual checkpoint/cache rewriting, authority change or invented evidence. Do not reject these merely for predating the retry path (including safe decoding of retained serialized state); unsupported legacy versions remain unsupported. Changed protected contracts still require ordinary correction and fresh approval. Update concise README and affected LOOP-10, REV-5/6/7 prose, maintained Gherkin and `spec/quint/build.qnt` semantics together, not a competing pipeline. No protected production edit is required.

## Decisions
- Use the existing explicit resume command; no new option, operator context input, automatic recovery or approval. KOGEN-033 diagnostic input is separate. (source: request)
- Keep Sol 6.1 high shaping/review and medium building, with the saved reviewer as targeted repair owner. No new model role or policy. (source: request)
- Qualify only synthetic local projects, Git and fake provider fixtures; never read/copy ElixirDrops logs or credentials, mutate global host configuration, recover the live app, release/deploy/push, approve or Build this repair during shaping. (source: request)
- Cross-version qualification uses `/Users/almirsarajcic/Areas/Kogen/studio-work/kogen-dev/failfast-c3ee2a8e/bin/kogen` only as the retained old executable input, never a production dependency. The reusable acceptance fixture accepts `KOGEN_REOPEN_OLD_BIN` and `KOGEN_REOPEN_NEW_BIN`; ordinary maintained tests must be portable and need neither that absolute path nor private artifacts. (source: request)

## Tests
- Explicit resume replaces terminal changes replay with fresh verification and same-reviewer explicit clearance: installed-CLI clear scenario, reproducing earlier green/approval then final setup failure and changes (regression)
- Complete fresh verification is required and stale green/approval cannot override unresolved, fresh-red or setup-failed blockers: repeated keep, red and setup-red scenarios with exact gate traces and no commit (scenario)
- Reviewer scoped edits still require external exact verification before signing one ordinary commit: repair scenario, signature/tree/hook checks (scenario)
- Verification and continued reviewer interruptions retain owner, guards and safe resumability without terminal replay: interrupt-verify and interrupt-review scenarios; extend maintained resume tests for provider failure at the continued request (integration)
- Retained signed c3ee2a8e version 2 checkpoints reopen without rewriting and without stale evidence: cross-version clear and red scenarios using old-created runs and newly packaged executable; record executable versions and signature verification on macOS (scenario)
- Custody, immutable failed artifacts, lineage, original finding/conversation and cumulative known usage survive retry/repeated attempts: shared installed fixture assertions in every mode, plus interrupted-request unknown usage checks (integration)
- Existing drift/legacy/uncertain tool/commit refusal, landed no-op and no-duplicate-commit rules remain unchanged: maintained resume fixture matrix and commit-boundary tests; do not duplicate the general matrix (existing)
- LOOP/REV state semantics invalidate prior approval/evidence on blocked reopening and require new exact green approval: update maintained build Quint tests and this Intent's small retry model (integration)

## Feasibility
- Retained executable reports `kogen c3ee2a8e (2026-10-19)`; macOS codesign verification succeeds; parent installed Node/Quint/Cucumber paths exist. (probe 1: exit 0, 0.2 s)
- Initial model probe exposed incorrect nondeterministic binding scope; corrected before submission. (probe 2: exit 1, 0.2 s)
- Corrected retry model typechecks and satisfies Safety for seed 2033, 200 samples, 30 steps on Quint TypeScript. (probe 3: exit 0, 0.7 s)
