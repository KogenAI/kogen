# Tighten reviewer style discipline

Slug: reviewer-style-discipline
Model: not applicable — static instruction and documentation policy; no new state or transitions
Acceptance:
- .kogen/intents/reviewer-style-discipline/acceptance.feature
- features/steps/reviewer_style_discipline_steps.js

Clarify the existing independent reviewer/fixer policy in `lib/kogen/review.ex`, `docs/testing-rules.md` (The reviewer) and `spec/prose/06-reviewing.md` (REV-4). Replace the permission to remove trivial nearby dead code and to correct small issues merely when useful with supported-current-defect/requirement discipline. Keep the reviewer strong: direct scoped repairs, useful regression tests and explicit existing project conventions remain in scope. Mechanically enforceable style belongs to existing configured tooling, not discretionary polish. Harmless preferences may remain nonblocking notes, not required edits.

Use the five policy paragraphs specified as expected output in acceptance as literal emitted instruction text (whitespace may wrap). Integrate them coherently with the current instructions rather than leaving contradictory cleanup permission elsewhere. Maintained documentation should express the same policy naturally; it need not duplicate the paragraphs verbatim. Preserve the existing requirement, concrete violating path/counterexample and observable consequence standard, including for documented requirements without a linter rule. Minimal incidental changes necessary for a demonstrated repair or configured style/project requirement are allowed; proximity or personal preference alone is not justification.

This is Almir's bounded policy clarification requested on 20 October 2026 after discussing Lab review-polish observations, not a new lever or a measured performance claim. Do not add configuration, caps, helpers, dependencies (including Credo), a planner or reviewer stage. Do not change Studio source/runtime, providers/models/tools, caching, orchestration, approval/protection/verification/commit behavior, or signed history. Preserve unrelated work. The ordinary native pipeline owns implementation, appropriate checks, independent review and signed commit; the request stays outside source.

## Decisions
- Delegate mechanical formatting/style to existing configured formatters/linters/checks and fixers, preserving checks and settings without adding dependencies. (source: request)
- Judge approved Intent requirements, explicit existing project conventions and demonstrated current correctness, safety, scope and meaningful-test defects; no linter rule is needed for an actual documented requirement. (source: request)
- Remove permission for preference-only renaming, rearrangement, abstraction changes, speculative refactoring and harmless nearby dead-code cleanup; retain minimal incidental changes necessary for supported repairs or configured style/project requirements. (source: request)
- Treat unchanged correct-code approval as success with no edit quota; harmless preferences do not block or require edits. (source: request)
- Preserve one independent strong reviewer/fixer, direct repairs, useful regression tests, same-reviewer continuation and all existing delivery safeguards. (source: request)
- Keep deterministic evidence limited to actual emitted instructions and maintained policy text, not predicted reviewer behavior or performance. (source: request)

## Tests
- Mechanical style is delegated to existing configured tooling without weakening settings: inspect the actual installed review request for the literal delegation paragraph in acceptance (integration)
- Approved requirements/conventions and demonstrated defects remain repairable even without a deterministic rule: inspect the actual emitted criteria alongside the preserved requirement/counterexample/consequence and useful-regression-coverage instructions (integration)
- Opportunistic polish permission is removed while necessary incidental edits remain allowed: inspect emitted policy and reject the old cleanup permissions in emitted instructions, installed testing rules and maintained REV-4 prose (regression)
- Unchanged correct-code approval succeeds without an edit quota or preference blockers: inspect the emitted success paragraph and land the existing fake-provider fixture with no reviewer edits, checking the actual committed builder contents (integration)
- Documentation matches the narrowed emitted policy: check the maintained reviewer sections for tooling, conventions, incidental-change and unchanged-approval guidance and absence of the old permissions (integration)
- Independent direct repair, same-reviewer verification failure handling, notes, protection, approval and commit safeguards remain unchanged: retain `test/integration/build_boundaries_test.exs` and `spec/features/06-reviewing.feature` coverage, and inspect preserved safeguard text in the captured request (existing)

## Feasibility
- Scratch has `mix` and `mise` on PATH; private shaping observations are not copied into exploratory scratch, so use authoritative readiness feedback to inspect acceptance results. (probe 1: exit 0, 0.0 s)
