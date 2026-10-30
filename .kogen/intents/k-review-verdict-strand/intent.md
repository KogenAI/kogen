# Preserve green candidates after verdictless review

Slug: k-review-verdict-strand
Model: .kogen/intents/k-review-verdict-strand/model.qnt invariants=SafeStop,NoImplicitApproval seed=17 samples=100 steps=20
Acceptance:
- .kogen/intents/k-review-verdict-strand/acceptance.feature
- features/steps/k_review_verdict_strand_steps.js

A completed green candidate must remain reviewable without rebuilding when an independent reviewer never submits a verdict. Retain the existing bounded reminder and single automatic fresh-review policy, and the existing explicit `kogen intent resume <build-id>` review-only recovery. Never manufacture approval. Make both incident shapes deterministic regressions using the existing fake provider, temporary Git repositories and real Build/Resume entry points. No paid requests are needed.

The current checkout already contains forced-tool provider-fault handling and K-REVIEWRETRY-2 regressions. Preserve these; do not assume that their existence establishes the second incident's recovery. Extend the local Build orchestration and its tests as necessary, without changing the protected loop dependency or pin. No CLI command/option or increased limit, timeout or retry allowance is permitted.

## Decisions
- Keep a supported accurate review-only recovery path for the same exact green candidate instead of requiring a rebuild when reviewers fail to submit. A verdictless ending is never approval. (source: request)
- Keep genuine findings, rejections, source-delivery requirements and unsafe-drift refusals intact. (source: request)
- Use local scripted reviewers only; no paid provider requests. (source: request)

## Source comparison
- Addressed: request Need and incidents 45d63b0d and c8de4b13 by the three executable acceptance rows and tests below: reset/forced prose handling, two verdictless reviews with pinned source and supported Resume, and truthful changed-tree refusal. The historical identifiers, tree 7791d35a, kogen 5d93641 and commit 021ff60 identify evidence, not fixture hashes to fabricate.
- Addressed: incident 1's reset 656837 -> 297809 bytes, prose, forced 78-token response and erroneous unread exemption; incident 2's automatic review 2, forced prose, subsequent read_file/shell and source prefill parts 30-42 (90613 bytes), and misleading changed-tree refusal are replay shapes, not requirements to reproduce historical provider token counts or exact serialized sizes. Tests must actually cause a reset and pinned-source progress rather than merely label them.
- Addressed: request constraints prohibit new commands/options, raised limits/timeouts/retries and paid tests; preserve substantive changes verdicts and rejections using existing review regression coverage plus the safety row.
- Omitted: remote evidence retrieval from kogen-runner:~/logs/s-mcp-invites-run-c8de4b13/log.jsonl and build-notes/delivery/k-reviewretry2/INTENT-REQUEST.md is not required runtime behavior; the supplied observations are preserved here as historical evidence, not claimed local measurements.
- Superseded: no existing safety boundary is superseded. Existing K-REVIEWRETRY and K-REVIEWRETRY-2 behavior remains the baseline; false green-tree drift classification and exemption of forced prose must not strand its candidate.

## Tests
- A reset followed by a forced prose-only answer cannot spend an unread-progress exemption or become approval: TestKReviewVerdictStrandReset through real Build with fake reviewer, including existing TestKReviewRetry2LogReplay coverage (regression)
- Two verdictless reviews with genuine pinned-source delivery leave an exact-green review-only checkpoint and explicit Resume starts a fresh review without builder/check replay: TestKReviewVerdictStrandPinnedResume through Build and CLI Resume (regression)
- A refused review-only recovery names the actual unsafe fact and preserves candidate, HEAD, index and approval; real findings/rejections still stop or repair normally: TestKReviewVerdictStrandSafety plus existing review safety/blocker tests (regression)

Implementation test requirements: TestKReviewVerdictStrandReset must observe actual transmitted forced submit_review selection surviving a reset, a provider_fault identifying route/model for a text-only forced response, ordinary no-tool exhaustion (not unread_progress_exempt for that response), then a fresh independent review. TestKReviewVerdictStrandPinnedResume must exercise two successive verdictless reviewers, tools and completed source prefill/read progress around the forced turn, on one completed green pass. Observe the current tree and saved pass rather than trusting the eligibility event. The stopped result must retain review_only with exact green tree and spent automatic retry; CLI Resume must obtain a valid verdict from one fresh reviewer and land only the reviewed green tree, with no builder or completed verification rerun. Include uncommitted reviewer edits in the first automatic retry to preserve existing discard/log semantics; the unchanged second reviewer must not cause false drift. Use actual generated fixture source for source-part counts; do not hard-code historical hashes as synthetic proof.

TestKReviewVerdictStrandSafety must contrast unchanged green recovery with actual candidate edits and HEAD/index/protected/custody refusal using existing fixture helpers and safety tests where applicable. For an actual tree mismatch report observed versus green identity and changed paths (or the concrete inability to inspect them), not a generic claim unsupported by tree observation; check higher-priority HEAD/index/custody causes accurately rather than mislabelling them as content drift. Do not discard edits at an explicit refusal or silently restore an edited stopped candidate. Check valid changes/blocking verdicts are not treated as missing verdicts, and rejected verdict allowances remain independent and bounded. Run existing affected reviewretry, review delivery and blocked-review tests unchanged unless their asserted behavior is explicitly corrected here.

## Feasibility
- Local inspection: review.go owns reminder/exemption classification and review_retry.go owns tree-bound retry/checkpoint eligibility; neither requires editing protected loop files. No external protocol change is requested.
- Quint typecheck succeeded in scratch (exit 0, 0.4 s).
- evidence: {"id":"named-test-observer","kind":"observer","inputs":["features/steps/k_review_verdict_strand_steps.js"],"observers":["features/steps/k_review_verdict_strand_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_review_verdict_strand_steps.js --control good","exit":0,"output":"accepted named test\n"},{"name":"bad","command":"node features/steps/k_review_verdict_strand_steps.js --control bad","exit":1,"output":"rejected absent named test\n"}]}
