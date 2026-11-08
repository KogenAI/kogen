# Clarify published specification wording

Slug: k-spec-wording-contradictions
Model: not applicable — documentation wording has no meaningful state
Acceptance:
- .kogen/intents/k-spec-wording-contradictions/acceptance.feature
- features/steps/k-spec-wording-contradictions__text.js

Fix Studio issue cafd3765-acd9-47e9-b833-201416006c2b (KOGEN-010), documentation wording only. Do not edit runtime code or configured checks. Historical line numbers identify passages, not current offsets. Correct LOOP-11's missing conjunction and the packaging README usage-introduction fragment. Leave all already-corrected passages unchanged.

## Decisions
- State plainly that VER-5 keeps the whole output through 60 lines, otherwise the first 30 and last 20; leave already-corrected wording unchanged (source: request)
- Preserve the current three acceptance variables and KOGEN_NODE, KOGEN_CUCUMBER and KOGEN_QUINT, making the Node/Cucumber conjunction grammatical (source: request)
- Leave already-corrected CLI introduction, provider status, interruption/process rules and testing-strategy wording unchanged; no agreed, does today or historical development phrasing belongs at the cited passages (source: request)
- Make the packaging usage introduction 'Run these commands in a Git repository with at least one commit (a Build needs a clean working tree, so keep the request file outside the repository, or commit it):'; preserve README's already-complete Quickstart introduction (source: request)
- Human review must evaluate that the prose states the current rules and has no behavioral impact; substring acceptance does not claim semantic proof of either (source: request)
- The existing suite must stay green under the unchanged configured verification commands; this is the normal whole-Intent verification requirement rather than a duplicate nested suite invocation in documentation acceptance (source: request)

## Source comparison
- Addressed request (1) by preserving current VER-5 wording and checking its requested 60/30/20 rule in acceptance.
- Addressed request (2) by correcting LOOP-11's remaining missing conjunction while retaining the now-current three VER-3 acceptance variables; the obsolete two-variable count is not restored.
- Addressed request (3) through the CLI introduction, GPT-4, CLI-7/CLI-9 and test-doubles acceptance rows. Those passages already lack the reported history wording. The request explicitly says 'If a location is already fixed on main, leave it'; therefore green baseline assertions for these passages are intentional preservation checks, not unimplemented removal claims.
- Addressed request (4) with README preservation and packaging introduction correction. The README line number now lands in a code block; the named usage introduction is the relevant passage.
- Addressed 'existing suite stays green' with normal unchanged configured checks. Addressed 'no behavior impact' with a documentation-only implementation boundary and independent review. No runtime change or new product behavior is authorized.

## Tests
- none: documentation-only change; acceptance checks published copy and configured existing checks remain mandatory in whole verification.

## Feasibility
- none
