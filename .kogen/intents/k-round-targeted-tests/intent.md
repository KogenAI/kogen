# Document the targeted-test adoption gate

Slug: k-round-targeted-tests
Model: not applicable — research documentation changes no runtime state
Acceptance:
- .kogen/intents/k-round-targeted-tests/acceptance.feature
- features/steps/round_targeted_research_steps.js

Deliver docs/round-targeted-tests.md as a research-only decision record for Studio kogen round-targeted-tests r2. No builder prompt, default, command, flag, option, timeout, retry, limit, verification or review behavior changes. This deliberately defers runtime adoption and measured before/after speedup until the existing bss1 result; it does not claim to fix builder execution time now.

## Decisions
- Preserve the Lab adoption gate; proceed with existing evidence only. buildspeed-screen-20261030 has no result or ledger row and nothing adopted; bss1 main (Kogen d42f6ccc, g0 vs g1) is admitted and pending; the dry run graded one cell per arm and decides nothing. Do not duplicate the screen, poll it or promote guidance. These are caller-reported 31 Oct facts, not a fetched Lab result. (source: answer 1)
- Keep targeted test execution separate from fast test authoring: issue f877f021 and Lab study test-authoring-guidance-20261031 are unrun and their wording is not accepted. (source: request)
- Keep complete configured verification and independent review for every native and external lineup; no new option. (source: request)

The record must compare actual rendered native builder and external Claude Code Build framing, quoting the relevant text and identifying source revision, rendering/test entry points and capture method. Use existing local render/capture fixtures, not live provider calls. Native already asks for focused/fail-fast tests, avoidance of duplicate whole gates, preservation of failure status and foreground finite tests without sleep/tail/ps polling. External uses its own Constraints preface and append-system-prompt, not the native prompt: identify the scoped-repair guidance gap without changing it. Include both paths' verification/review ownership text; source-only comparison must not be mislabeled as rendered capture. Preserve all configured checks as-is.

Retain the reported research profile and limitations: 42 Builds on 30 Oct; 19.8 ks/34% in-round builder tests, kogen-loop 25%, total tests 76% of summed Build wall. Build 0fe59528 had 8,660 s of 10,918 s; 416c6a6c 2,932 s; f942dd77 2,210 s; d84e3244 1,498 s; 312149a3 1,497 s. About 1,100 s per Build is an upper bound overlapping K-GO-TEST-CRITICAL-PATH and K-ROUND-FULL-SUITE, not additive or measured savings. Transcripts show commands, not unchanged-package trees. Reproducing commands include go test ./..., go test ./build and the full race pass plus sleep-polling logs.

Retain answer 1's sharding evidence as separate evidence, not targeted-test adoption proof: laptop n=3/arm plain Go tests failed 3/3 on ./build's 10-minute timeout; four concurrent -run shards passed 3/3 at mean 461 s, p=0.05. MacBook plain failed 2/2; one sharded run took 474 s with one flaky test. Load rose to 15–18 from 9–10. Builder test commands occupied 50% of build wall in 19 MacBook Kogen + Claude Code cells. Historical roadmap screenshots prove neither landing nor priority changes.

Specify the future measurement gate without executing a duplicate study: obtain current bss1 results and adoption decision first; compare same kinds of Builds, native/external lineup, change scope and host conditions, separate in-round test wall time from Kogen verification and total wall, record failures and full-check/review coverage, distinguish observed savings from upper bounds and unknown unchanged-package retesting. A pending result means no adoption and no speedup claim. No new tooling or study runner is requested.

## Source comparison
- addressed: request Problem/Evidence and answer 1 research evidence are retained in the record with numbers, commands, limitations and distinct evidence scopes (contract outcome paragraphs; acceptance retained evidence).
- addressed: r2 asks comparison of actual rendered paths, complete verification/review and execution versus authoring separation (contract rendered comparison and Decisions; acceptance comparison).
- superseded: original immediate runtime fix and before/after delivery are deliberately narrowed by answer 1 to research-only preparation; no prompt/default adoption or speedup is authorized, and bss1 remains the gate (contract Decisions and measurement paragraph; acceptance gate).
- omitted: no live Lab fetch is possible from supplied access; answer 1 supplies pending status rather than results. Do not fabricate an export, ledger row or fetched result (contract Decisions).

## Tests
- Research record retains evidence and the pending adoption gate: acceptance checks the delivered documentation (scenario)
- Rendered-path comparison identifies guidance gap without adoption: inspect quoted rendered captures and their provenance in the delivered record (scenario)

## Feasibility
- none
