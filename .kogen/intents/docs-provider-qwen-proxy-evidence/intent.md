# Say QwenCloud Build evidence came via fleet proxy

Slug: docs-provider-qwen-proxy-evidence
Model: not applicable — the change is one documentation sentence and the test that checks it; there is no state
Acceptance:
- .kogen/intents/docs-provider-qwen-proxy-evidence/acceptance.feature
- features/steps/docs-provider-qwen-proxy-evidence__steps.js

The QwenCloud Build result behind the label in `docs/providers.md` (qwen4-max at effort medium, 8 of 8 Builds landed with Claude Review, Lab run recorded in the Studio document qwen-build-vs-sonnet-20261118) was produced through the fleet proxy, a keepalive proxy in front of the QwenCloud Token Plan endpoint, and not through the route a public install uses. Whether a Build run directly from a public install lands the same way is not yet known; it is under test. The page must say so next to the label. Studio evidence: providers-role-screen-20261120 (section "Docs check 21 Nov").

Scope: `docs/providers.md` and `cli/providers_guide_test.go`, the Go test that already checks that page. No other file.

In the QwenCloud section of `docs/providers.md`, directly after the label line (`experimental: Build verified with Claude Review; Shape and Review not qualified`) and before the setup example (the yaml code block), add one sentence on its own line stating that the Build evidence came through the fleet proxy and that the direct public-install Build is still under test. The sentence is added once. No other sentence on the page is reworded or removed to make room for it, no existing sentence outside the QwenCloud section changes, and no emoji is added. Nothing is replaced or removed.

`cli/providers_guide_test.go` gains one test that checks the sentence: the QwenCloud section has it directly after the label line, it names the fleet proxy, says the direct public-install Build is still under test, and the page names the fleet proxy once.

## Decisions
- The sentence is a single line directly after the label line, separated by blank lines, so it comes before the existing sentence that begins "The label above"; the label line itself and every other existing line stay unchanged. (evidence: docs/providers.md; cli/providers_guide_test.go) (source: request)
- The sentence states the Build evidence came through the fleet proxy and that the direct public-install Build is still under test, in those words ("fleet proxy", "direct public-install Build", "still under test"). (source: request)
- The Go test to extend is `cli/providers_guide_test.go`, found by searching the repository for the test that reads `docs/providers.md`; the label line and the setup example (the first code fence of the QwenCloud section) were located by reading the page. (evidence: cli/providers_guide_test.go; docs/providers.md) (source: request)
- The sentence is added once: the page names the fleet proxy exactly once. (source: request)
- No emoji is added and no existing sentence outside the QwenCloud section changes. (source: request)
- The new Go test follows the existing `TestProvidersGuide` name prefix and reuses `readProvidersGuide` and `qwenLabel`. (evidence: cli/providers_guide_test.go) (source: request)
- Add one single-line sentence directly after the QwenCloud label line (line 24 of docs/providers.md), before the setup example yaml block, and extend cli/providers_guide_test.go with one test for it. (decision: D1, round 1) (constraint: only docs/providers.md and cli/providers_guide_test.go change) (constraint: the sentence is added once) (constraint: no emoji) (evidence: docs/providers.md; cli/providers_guide_test.go) (assumption: I ran the Go tests and acceptance step logic in a scratch clone with the correct and wrong overlays; Kogen readiness has not yet confirmed them.) (source: request)

## Source comparison
- Request: sentence about fleet proxy and the direct public-install Build under test, in the QwenCloud section directly after the label line and before the setup example — addressed in `docs/providers.md` and checked by acceptance and by `cli/providers_guide_test.go`.
- Request: the sentence is added once, no other sentence reworded or removed, no emoji, no sentence outside the QwenCloud section changes — addressed; acceptance compares the page lines with the committed page.
- Request: Studio document names (qwen-build-vs-sonnet-20261118, providers-role-screen-20261120) and the qwen4-max / effort medium / 8 of 8 figures are background evidence; the page keeps its existing label and the new sentence does not need to repeat them.
- Request: scope limited to `docs/providers.md` and the existing Go test file — no other file changes.

## Tests
- The QwenCloud section carries one sentence after the label line and before the setup example naming the fleet proxy and saying the direct public-install Build is still under test: add a test to `cli/providers_guide_test.go` that reads the QwenCloud section (unit)
- Existing page facts and the provider table stay intact: the existing `TestProvidersGuide` tests in `cli/providers_guide_test.go` keep passing (existing)
- End to end: the acceptance scenario reads the page, runs only the `TestProvidersGuide` tests of that Go test file and compares the page with its committed version (scenario)

## Feasibility
- none
