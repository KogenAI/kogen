# Restore oversized review catalog scenarios

Slug: k-review-catalog-repin
Model: not applicable — repair fixtures and existing wiring without changing the review state machine
Acceptance:
- .kogen/intents/k-review-catalog-repin/acceptance.feature
- features/steps/acceptance_green_shape_steps.js

Fix the two chapter-06 reviewing regressions with the loop pinned at af456d5. Change test/acceptance/support/fake-servers.js so the fake builder actually produces oversized candidate source within the loop's 131072 UTF-8 byte per-response visible-output bound. Preserve Unicode/CRLF content and deleted literal-path coverage. Repair Kogen-side catalog wiring if the valid fixture exposes a defect. Never edit cli/third_party/kogen-loop/ or cli/loop-pin.json. Do not weaken spec/features/06-reviewing.feature or its assertions in test/acceptance/support/handlers.js. No new command, flag, option, timeout, retry or limit change.

The following are explicit required CLI outcomes, not merely references to historical tests. Starting with the Background in acceptance.feature, script build-large-review-evidence must make `kogen intent build is-even` exit 0, deliver bounded complete pinned source evidence to independent Review before approval, omit builder conversation/tools/results from Review, send no builder request after Review starts, record exactly 1 review stage and 1 verification pass, and add exactly 1 HEAD commit. Complete evidence includes source_bytes greater than 524288, matching complete source/file hashes, deleted literal-path metadata/content, exact complete delivery in a continuation, rejection of premature same-response approval and reviewer requests no larger than 524288 bytes. With the same Background and script build-large-review-evidence-drift, the command must exit 1, stdout must contain both `candidate/resume_refused` and `working-context history custody missing, changed or unsafe`, and HEAD must remain unchanged. Altered pinned custody must refuse before another tool or approval.

## Decisions
- Preserve complete independent review delivery and tamper refusal. (source: request)
- Permit fixture generation changes within the deliberate pinned response limit; a small ordinary candidate is not an acceptable substitute. (source: request)
- Execute each named Build exactly once in approval acceptance without repeated Examples rows. (source: request)

## Source comparison
- Addressed: the original K-REVIEW-CATALOG-REPIN request's spec/features/06-reviewing.feature:33 and :44 outcomes are copied into acceptance.feature and specified explicitly above. Preserve af456d5 and both protected paths; allow Kogen-side fixture repair without weakening scenarios.
- Superseded: initial likely review-request-shape diagnosis is not assumed proven. Read repository code shows the fake emits oversized argument deltas and the pinned loop bounds them. Build 99d4c402's retry/ordinal diagnosis remains builder-reported, not independent execution evidence. The host-local ~/work.noindex/old/k-review-catalog-repin-1427b/.kogen/local/runs/99d4c402 is historical diagnostic evidence, not a runtime input.
- Addressed: reported main ecde7c0 266/264/2 results, c81cea3, re-pin 63aac76 and adaptation bc54c65 explain the regression but confer no current green evidence. Configured checks must pass and the complete suite is delivery's post-landing measurement.
- Omitted deliberately: six Builds in approval acceptance, which exceeded the 120 s step limit on 1 Nov 09:14Z. Three repetitions per original selector remain required implementation evidence below, not repeated acceptance rows. No product outcome is omitted.

## Tests
- Complete oversized delivery before approval: preserve the original :33 installed-CLI scenario and complete pinned-source assertions; execute its copy in acceptance.feature once (regression)
- Altered custody refuses with the specified diagnostics and unchanged HEAD: preserve the original :44 installed-CLI scenario; execute its copy in acceptance.feature once (regression)
- Fixture produces oversized source within the pinned per-response bound: add focused local coverage of the changed fixture generation, observing actual generated source and serialized response argument bytes, not retry ordinal advancement as success (integration)
- Packaged release repeatability: run spec/features/06-reviewing.feature:33 and spec/features/06-reviewing.feature:44 each three times against the freshly packaged release using test/acceptance's strict non-live Cucumber runner with steps/*.js and support/*.js; retain actual results as implementation evidence (regression)
- Configured checks remain required: run all configured checks; measure the complete non-live suite after landing rather than expanding approval acceptance (existing)

## Feasibility
- none
