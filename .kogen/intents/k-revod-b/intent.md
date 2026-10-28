# Correct on-demand review reset guidance

Slug: k-revod-b
Model: not applicable — this changes handoff copy, not the review state machine
Acceptance:
- .kogen/intents/k-revod-b/acceptance.feature
- features/steps/krevodb_steps.js

Correct only the on_demand branch of the reviewDelivery reset handoff in cli/build/material.go. The manifest/catalog still lists parts and files. Explain retrieval by part id or path and line range, include exactly `Read only the parts you need; no part is required before a verdict.`, and state that nothing is appended automatically. Remove the on-demand claims about automatic source-data appends, mandatory rereads and batches. Preserve all other handoff elements: authority, native delivery facts including what was already read, image custody/currentness and verdict rules. Do not change runtime behavior, limits, events, prefill or request construction beyond this mode-specific handoff copy.

## Decisions
- Only on_demand reset guidance changes; parts is the default and its handoff, requests and prefill remain byte-identical. (source: request)
- A reviewer may approve without reading any part in on_demand, including after reset. (source: request)
- Shared-host work uses temporary directories, no synthetic CPU load, and never stops processes by name or pattern; stop only owned pids. (source: request)

## Source comparison
- addressed: request Why and What to build target reviewDelivery (currently cli/build/material.go:934–995); the outcome above replaces the inaccurate automatic-append/batch guidance only for on_demand.
- addressed: request Acceptance is covered by the two named real fake-provider regression tests below, run by acceptance.feature; exact required sentence is retained verbatim in the feature.
- addressed: Must stay requires unchanged default handoff/requests/prefill and all configured checks; retain existing tests and run the full configured gates.
- addressed: Host safety is retained in Decisions and applies to all fixture execution.
- omitted intentionally: no benchmark changes or runs; research/benchmarks/proposals/read-context-mechanisms-2026-10-28.md is motivation, not a request to modify research. No supplied reproducer or counterexample is superseded.

## Tests
- On-demand reset carries accurate retrieval and optional-read rules while retaining all other handoff content: add TestKRevodBOnDemandReset in cli/build using newEnv, fakeProvider, resetHandoff and existing long-review/reset fixtures; assert an actual provider request after a working-window reset contains the exact feature sentence, manifest/catalog parts/files and retrieval guidance, no mandatory-read/batch/automatic-append claims, and unchanged authority/delivery/verdict facts (regression)
- On-demand long review can approve without reading parts after reset: the same TestKRevodBOnDemandReset must produce a real reset with bounded fixture exchanges, then approve and land with zero parts_read and no native prefill; do not manufacture a reset message or merely call reviewDelivery (integration)
- Default parts handoff remains byte-identical: add TestKRevodBPartsReset using the same long-review fixture in parts mode; compare the complete handoff guidance bytes against a literal frozen from the original reviewDelivery note at HEAD 3095b713323520759d3553fd0cc7a05f9aa95665, not a value recomputed from modified production; retain source/image facts and authority/verdict rules and complete the review by the existing parts protocol (regression)
- Default requests and prefill, and every other behavior, limit and event remain unchanged: preserve existing review_delivery, review_prefill, review_budget and on-demand tests and pass all configured checks (existing)

Implement the two named tests as ordinary editable Go regression tests, not in the protected step library. The acceptance bridge requires each named test to execute and pass; an empty go-test selection is not success. Reuse cli/build/review_delivery_test.go and review_test.go fixtures and keep the long-review exchanges bounded. Freeze the original note exactly, including spaces and punctuation, before editing production.

## Feasibility
- none
