# Correct init prerequisite in configuration guide

Slug: docs-config-init-without-chatgpt
Model: not applicable — documentation has no meaningful state
Acceptance:
- .kogen/intents/docs-config-init-without-chatgpt/acceptance.feature
- features/steps/docs-config-init-without-chatgpt__copy.js

The landed update c8b3cae corrected README.md, packaging/README.md and docs/getting-started.md, but docs/configuration.md still says: "Automatic command discovery with bare `kogen init` still requires ChatGPT; configuration-first bootstrap below does not." That is false: automatic `kogen init` discovery works with any supported signed-in discovery route, including Claude Code and Anthropic, and does not require a ChatGPT account. Replace the claim in docs/configuration.md with accurate guidance and keep the surrounding guidance that Shape, Refine and Build/resume validate the roles they actually use. This is documentation only: no provider implementation, model lineup, authentication behavior or protected project/dependency configuration changes.

## Decisions
- The sentence at docs/configuration.md lines 202-203 becomes: "Automatic command discovery with bare `kogen init` works with any supported signed-in discovery route, including Claude Code and Anthropic, and does not require a ChatGPT account; configuration-first bootstrap below remains available." The sentence "This repository retains its existing ChatGPT bootstrap lineup." before it and "Shape checks its role, Refine checks Shape, and Build/resume checks Build and Review; unused providers need no login." after it stay unchanged. (decision: D1, round 1) (constraint: Edit only docs/configuration.md) (evidence: docs/configuration.md) (source: request)
- The sentence at docs/configuration.md lines 285-286, "Bare init discovery still requires ChatGPT or Claude Code.", states the same stale prerequisite (it omits Anthropic and implies ChatGPT or Claude Code is needed), so it is corrected in the same file to: "Bare init discovery works with any supported signed-in discovery route, including Claude Code and Anthropic, and does not require a ChatGPT account." The following sentence "No preset command, init provider selector or automatic router is added." stays. (decision: D2, round 1) (constraint: Edit only docs/configuration.md) (evidence: docs/configuration.md) (assumption: the user accepts correcting this second stale sentence in the same file as part of the same claim) (source: request)
- The request's statement that init discovery works with Claude Code and Anthropic after the init provider changes is taken as stated; this shaping did not verify it against cli source, and the docs only describe it. (decision: D3, round 1) (evidence: .kogen/intents/docs-init-works-without-chatgpt/intent.md; docs/getting-started.md) (assumption: init provider behavior is as the request states) (source: request)
- Acceptance reads docs/configuration.md with whitespace collapsed (so line wrapping is irrelevant), requires the exact new phrases, rejects the old ChatGPT-only phrases and any sentence that ties init or discovery to a ChatGPT requirement without negation. (decision: D4, round 1) (evidence: features/steps/docs-init-works-without-chatgpt__copy.js) (source: request)

## Source comparison
- Addressed: the stale sentence at docs/configuration.md lines 202-203 is replaced (scenarios 1 and 3).
- Addressed: the surrounding Shape/Refine/Build-resume role-validation sentence is preserved (scenario 2).
- Addressed: the matching stale sentence at lines 285-286 is corrected (scenario 1).
- Addressed: the old claim is rejected by acceptance (scenario 3).
- Omitted deliberately: README.md, packaging/README.md and docs/getting-started.md (already corrected by c8b3cae); provider implementation, model lineups, authentication behavior and protected configuration.

## Tests
- docs/configuration.md says automatic init discovery works with any supported signed-in route including Claude Code and Anthropic and needs no ChatGPT account: inspect the whitespace-normalized Markdown for the exact sentences (regression)
- Surrounding role-validation guidance is preserved: inspect the Markdown for the Shape/Refine/Build-resume sentence and the retained ChatGPT bootstrap lineup sentence (regression)
- The old ChatGPT-only claim is gone: reject the old phrases and any un-negated sentence tying init or discovery to ChatGPT (regression)

## Feasibility
- none
