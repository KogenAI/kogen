# Reconcile legacy usage coverage uncertainty

Slug: legacy-usage-coverage
Model: .kogen/intents/legacy-usage-coverage/model.qnt invariants=TokensStayRetained,NoSummaryDoubleCount,HonestAllocation seed=31 samples=100 steps=20
Acceptance:
- .kogen/intents/legacy-usage-coverage/acceptance.feature
- features/steps/legacy_usage_coverage_steps.js

Correct the local `kogen intent usage [RUN-ID] [--lineage] [--project DIR] [--json]` report, not the provider or historical records. The current reader retains only slug/ancestry from Build `result.json` and can therefore show correct retained token sums while omitting available summary uncertainty. Read the maintained native results alongside the existing bounded canonical log scan. Preserve all existing retained-attempt totals, filters, groupings, ordering, limits and the version-1 facts envelope; add coverage information, not synthetic request rows or summary token sums. Update `docs/usage.md` to explain the distinction.

The retained f4637b88 evidence supplied with the request establishes 84 completed legacy rows, no retained failed row, retained unknown_usage=0, and known input=28312420, cached=5974784, output=38982, reasoning=2038. Its separate native result has outcome=context_exhausted, provider_failure.code=context_length_exceeded and unknown_requests=1. The report must expose that additional uncertainty without changing those observations. The acceptance fixture reproduces this discrepancy with deterministic synthetic rows of the same cardinality and exact sums; it does not purport to recover missing historical rows.

Add `data.coverage` to successful machine reports with these fields:

- `retained_attempts`: the existing deduplicated selected `totals.requests`, before display limiting.
- `retained_unknown_attempts`: the existing selected `totals.unknown_usage`, not a logical-failure count.
- `completed_operations`: number of distinct evidenced operation IDs with a completed selected physical attempt. Return null if selected retained rows lack the IDs needed to establish a complete logical count. A failed compatibility attempt followed by a completion for the same operation counts as two physical attempts and one completed operation. Do not invent operation IDs for legacy rows.
- `summary_unknown_requests`: nullable nonnegative integer for applicable native Build summary unknown_requests, reconciled across selected evidence scopes as below. This is the native unresolved logical-request counter, not a count of all physical attempts with unknown tokens, and not a failure count.
- `unrepresented_unknown_requests`: nullable nonnegative integer for applicable summary unknown requests not already represented by retained unresolved operations. An unresolved represented operation has failed/cancelled physical evidence with an operation ID and no completion of that operation in the covered evidence. A completed operation's earlier failed/unknown fallback attempt does not represent an unresolved logical request. Legacy completed rows do not represent an unresolved request. When ambiguous unidentified failed rows, conflicting evidence or uncertain attribution prevent exact reconciliation, use null rather than an invented subtraction. Never clamp a contradictory result into apparent reconciliation.
- `status`: `uncertain` if the summary comparison is unavailable, unattributable, inconsistent or leaves unrepresented uncertainty; otherwise `reconciled`. Reconciled describes only this summary counter comparison, not proof of complete usage, billing or token knowledge.
- `summaries`: safe records of available selected Build summary evidence, sorted by run ID, each `{run_id,source,unknown_requests,outcome,provider_failure_code}`. Source is the checkout-relative canonical result path. Missing/invalid unknown_requests is null, never an assumed zero. Outcome and provider failure code are bounded analytical identifiers, not raw provider prose. Missing optional values are null. A result whose declared build identity conflicts with its canonical run cannot be used as matched summary evidence; disclose the limitation.
- `omitted_summaries`: number of summary records omitted from display. Apply the existing `--limit` to this array separately from requests; reconcile using all scanned selected evidence, not just displayed summaries. No new option is needed.

For a standalone selected root run, a matched result's unknown_requests applies to that run. Native resumed results inherit cumulative unknown_requests; attempt_usage resets on resume but must never be added to retained tokens. For a fully selected, established linear root-to-leaf chain, use its terminal cumulative counter once, not the sum of parent and child counters. Match retained unresolved operations across that chain once by their actual IDs. An isolated resumed child does not establish an allocation of inherited uncertainty to that child. Branching, incomplete or conflicting ancestry must expose unknown allocation rather than summing overlapping counters. Independent established nonoverlapping roots may be combined; unrelated summaries must not affect a selected run. Do not use timestamps or lexical IDs to invent ancestry or choose a branch. The Quint model abstracts evidence arrival, a cumulative root/child counter of one, and fully attributable versus partial/filtered scope; it does not model provider execution.

Row filters still select retained observations exactly as before. A run-level summary cannot be allocated to role/model/effort/outcome/pass/repair/time slices merely because all displayed rows share that attribute. Keep the available summary records visible, but use null aggregate summary comparison fields and a limitation when filtered applicability is not established. A matching known slug can establish scope; unknown fields never establish a filter match. Groups remain retained-row aggregates, without allocating summary uncertainty to invented group keys. An absent summary, including empty history, is unknown coverage, not proof of zero calls or failures. Available unknown_requests alone never increments retained failed, cancelled, unknown_usage, requests, completed or token fields. Provider failure metadata can disclose an observed run failure but does not authorize inventing its attempt identity or counting generic unknowns as failures.

Use sorted `data.limitations` to disclose at least `summary_coverage_unavailable` for absent/unusable comparison, `summary_usage_unrepresented` for a known positive residual, and `summary_scope_unattributed` when available evidence cannot be allocated to the selection. Preserve existing limitations, especially legacy identities and unknown write fields. Further concrete ambiguity may be disclosed without making up counts.

Human output must visibly label the same distinction, using these lines with unknown nullable counts rendered `unknown`:

`Retained attempts: N; unknown usage attempts: U; completed logical operations: C`

`Summary unknown requests: S; unrepresented unknown requests: M; reconciliation: STATUS`

Print each displayed safe summary as `Coverage summary: <JSON>` and disclose omitted summaries. Retain existing known-token lines and row/group output. Neither format may imply that retained failed=0 establishes absence of run failures. No new failure/logical-operation total is inferred from summary-only evidence.

Keep scanning within existing canonical immediate run/history directories, byte/row/directory bounds and regular-file checks. Summary reads share those bounds; missing/damaged/capped evidence cannot produce an exact coverage claim. Do not read giant checkpoints, recursive archives, fixture repositories, review totals or remote/account history. Preserve records byte for byte and keep context/completion fast paths independent of usage scans.

This is one new post-landed corrective package. Preserve the committed prompt-cache-reuse-and-usage and cache-capability-fallback Intent packages and helpers. No provider policy, replay, model/effort, authorization, checkpoint, reviewer, gate or broad analytics redesign; no fabricated tokens, identities, timestamps, phases or rows; cached remains a subset of input. Write counts/lifetimes absent in legacy evidence remain unknown despite aggregate known-write zeros. No billing, ChatGPT weekly-quota conversion, cache-rate guarantee, benchmark, prewarm, paid probe, global installation/adoption, Go migration resumption or parked guidance-feature implementation. This package is not approval or Build authorization; exact approval, native Build, configured checks, independent review and signed commit remain separate normal boundaries. Preserve prior f91 qualification instead of repeating a whole-cache audit.

## Decisions
- Show retained physical observations, evidenced logical completions and summary-only uncertainty separately in both local human and versioned JSON output, preserving exact known sums and all historical bytes. (source: request)
- Reconcile only matched run/lineage/scope evidence; cumulative summaries and already-observed fallback uncertainty must not be double counted or turned into invented logical failures. (source: request)
- Use deterministic self-contained fixtures through a privately installed production CLI; do not depend on external retained evidence paths at test runtime, paid transport or global adoption. (source: request)

## Tests
- The 84-row f463-style summary unknown1 discrepancy is visible without changing exact known token sums or inventing a failed row: installed CLI JSON and human regression scenario (regression)
- Missing summary and summary-only history retain unknown coverage and never fabricate rows or zero missing usage: installed CLI absent-summary and summary-only scenarios (scenario)
- Retained unknown failed operations and completed fallback operations reconcile differently without double counting: installed CLI retained-failure and nine-completion/ten-attempt scenarios (scenario)
- Cumulative linear root/child summaries count once, isolated children remain unattributed and unrelated roots are excluded: installed CLI lineage and child-scope scenarios (scenario)
- Filtered summary allocation remains unknown while retained filters, groups and display limits keep their meaning: installed CLI filtered-scope scenario (scenario)
- Counter reconciliation, logical completion identity and ambiguous attribution follow the documented arithmetic: add focused callable Go usage calculation tests, including missing/invalid counters, identity mismatch, incomplete/branching ancestry and unidentified failures (unit)
- Canonical summary reads obey the existing scanner's file/size/cap boundaries without changing historical bytes: extend local usage scanner tests for summary evidence and retain existing damage/symlink/cap tests (integration)
- Existing cache transport/replay and compatibility safety, token validation/deduplication, argument/filter behavior and context/completion boundaries remain unchanged: retain their existing tests and committed acceptance helpers (existing)

## Feasibility
- The small evidence-reconciliation Quint model typechecked and its three invariants passed 100 TypeScript samples of 20 steps, seed 31. (probe 1: exit 0, 0.7 s)
- A private archive install succeeded, but the initial minimal usage fixture was refused as not_project because it lacked .kogen/project.yaml; the acceptance fixture includes that required project marker. (probe 2: exit 3, 16.4 s)
- With the project marker, a privately packaged/installed CLI accepted the canonical native result/log fixture and returned the version-1 usage envelope with the retained row and no summary coverage disclosure, confirming both the boundary and the defect. (probe 3: exit 0, 15.0 s)
