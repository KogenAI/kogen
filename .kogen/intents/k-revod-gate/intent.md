# Gate on-demand review on changed hunks

Slug: k-revod-gate
Model: .kogen/intents/k-revod-gate/model.qnt invariants=Safe seed=17 samples=20 steps=8
Acceptance:
- .kogen/intents/k-revod-gate/acceptance.feature
- features/steps/k_revod_gate_steps.js

In on_demand review, require complete reads of every pinned part covering changed hunks according to the manifest's per-part covered line ranges, then judge the candidate on the evidence read. Request any other part by id when a claim depends on it. Inspection completeness beyond these requirements is not required. Replace both the blanket complete-source rule and the current on-demand guidance that no part is required. Keep initial and reset instructions consistent. Missing required reads produce invalid-verdict feedback, not a product finding.

A blocking finding explicitly asserting no product defect (including an inspection-not-completed blocker) is invalid feedback, never review_blocked. Route it through existing invalid-verdict feedback, allowances, fresh-review and eventual review_invalid handling without increasing any limit, timeout or retry. Do not reject concrete defect findings merely because they mention inspection. Preserve the review tool schema and CLI. Record per-review hunk-covering part identities and actual completed part reads in run events; preserve existing parts_read count. Use the existing hash-bound complete-delivery ledger, including resets, not requested-read counts.

Compute required parts from manifest ranges, matching path and side of each hunk. Include diff parts spanning a hunk and file-text parts overlapping its candidate lines; deletion-only hunks are covered by their diff parts. Added textual files use their synthesized hunks; binary/gitlink entries with no textual hunks add no fictitious line requirement. Deduplicate in catalog order. A split hunk requires all overlapping parts, not only its first part. Preserve custody/current-tree checks and review independence.

Default parts-mode provider requests must remain byte-identical, including rules, source data, reset instructions and tool schema. Mode-specific policy must not leak into default requests. No CLI, provider transport, context ceiling, output reserve, timeout or retry changes. Update repository documentation of the on-demand exception without changing parts-mode authority rendering.

## Decisions
- Judge on read evidence after all hunk-covering parts are read; obtain other claim-dependent parts by id (source: request)
- Reject no-defect blockers as invalid review feedback rather than candidate defects (source: request)
- Retain default parts behavior and exact request bytes, independence and hash binding (source: request)
- Research gate: S-LEVERS re-review in on_demand must return a defect-based verdict (approval means no blocking defect), read at least all hunk-covering parts and avoid window overflow. Retain actual run evidence; deterministic fakes are not live qualification. Do not claim unavailable Studio data or credentials were exercised (source: request)
- Shared-host safety: temporary directories only for test projects; never kill by process name/pattern, only owned pids; no synthetic CPU load (source: request)

## Source comparison
- Addressed request What 1–3 in outcome, range computation, invalid feedback and per-review event requirements; executable cases cover the invalid blocker, minimal sufficient reads, missing reads and logs.
- Addressed Must stay and Acceptance through the parts-mode byte-equality regression and unchanged configured checks; no limits or CLI additions are authorized.
- Addressed Why reproducer: S-LEVERS Build 2c768016 (28 Oct 2026), Studio runner, review terra medium, review_material: {mode: on_demand}, parts=181, parts_read=2, changes blocker “The required inspection of the complete pinned candidate source was not completed... no product defect is asserted by this finding.” Reproduce that message and 181-part/2-required-part case in the deterministic regression, not a claim that those two historical reads covered the hunks. Preserve the 60 clean bench control cells with no pinned source as an empty-required-set control.
- Addressed research Gate as a separate retained real S-LEVERS re-review requirement, not replaced by a synthetic success claim. External authentication/resources may honestly stop this research; no paid sweep or automatic restart is authorized.
- Superseded current on-demand no-required-parts guidance and complete-pinned-source requirement only for on_demand. No requested behavior is intentionally omitted.

## Tests
- Require all hunk-overlapping parts including split hunks, additions and deletion diff ranges: TestKRevodGateHunkCoverage (unit)
- Reject the reported no-defect blocker through existing invalid handling, never review_blocked: TestKRevodGateInvalidBlocker using a fake reviewer through real Build (regression)
- Read hunk-covering parts only, approve and land with unread unrelated parts and per-review logs across reset: TestKRevodGateHunkApproval through real Build (integration)
- Reject premature verdict with unread required parts as invalid feedback, not a defect: TestKRevodGateMissingRead (integration)
- Preserve parts-mode requests byte for byte and no-pinned-source controls: TestKRevodGatePartsUnchanged plus existing parts golden/reset tests (regression)
- All configured checks remain green: unchanged configured verification (existing)
- Real S-LEVERS research outcome: retain re-review verdict, hunk-covering/read identities and window outcome separately from fake-provider tests (scenario)

The builder adds the named Go tests in cli/build using existing newEnv, fake provider, review catalog, event and Git fixtures. These tests are implementation tests, not protected acceptance artifacts. Each must assert the behavior above, not merely log success. TestKRevodGateInvalidBlocker includes the exact historical message and a concrete defect counterexample accepted as changes; exhaust existing invalid allowances to observe review_invalid rather than review_blocked. TestKRevodGateHunkApproval uses 181 parts with exactly two hunk-covering parts, verifies the real reads before approving and observes the landed commit. TestKRevodGatePartsUnchanged compares complete rendered requests with unchanged parts-mode expectations, not just part counts, and exercises the 60 empty-source controls. Use local deterministic fixtures; do not access or resume unrelated host work.

## Feasibility
- Model typecheck and TypeScript run passed with seed 17, 20 samples, 8 steps in scratch; initial absolute-path probe was refused before execution, then corrected to a scratch-relative path.
- No external protocol/library behavior changes require provider documentation or live paid probes.
- evidence: {"id":"named-test-observer","kind":"observer","inputs":["features/steps/k_revod_gate_steps.js"],"observers":["features/steps/k_revod_gate_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_revod_gate_steps.js good","exit":0,"output":"observer accepted\n"},{"name":"bad","command":"node features/steps/k_revod_gate_steps.js bad","exit":1,"output":"observer rejected\n"}]}
