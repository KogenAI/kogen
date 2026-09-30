# Make Build converge, recover and publish reliably

## Outcome

Fix the automatic Build (`mix kogen.build`) so it converges, recovers and
publishes reliably. One Candidate revision gets a complete offline gate; only
after it passes do selected provider-backed targets and a provisional
independent Review run concurrently against that frozen revision. Settlement
aggregates all target results and Review findings into one actionable handoff.
Only exact-tree receipts, an independent verdict and a post-settlement
evidence Review joined on the final Candidate may authorize publication.

Builds run through `mix kogen.build` only. The operator phase API
(`kogen.phase`, `operator.ex`, `phase_state.ex`, `manual-phase.exs`) was
jumpstart tooling and is removed from the product; this Intent has no
operator-driven phases, operator publication sidecar, or operator
adoption/recovery.

## Required control loop

1. Admit from the Approved package on a clean control checkout attached to the
   admitted branch. Freeze the base,
   branch, package bytes and digest, route/catalog, role profiles and budgets;
   create the Candidate, tracking/owner records, harness home, lock and write
   boundary before any provider role starts. Never treat manual
   edits or user/provider prose as controller receipts.
2. On tree T, run the complete `make check` gate once. Its single aggregate
   receipt covers the required offline selectors, the applicable preparation
   for each selected target, and validation of generated fixtures with
   provider access denied. Do not rerun a selector separately merely because
   it is also listed as scenario proof. Settle and persist all offline
   outcomes before dispatch. An offline/evidence failure produces one
   aggregated handoff and no provider dispatch.
3. Once offline passes, fan out every selected live target and one provisional
   read-only Review of exactly T. Use distinct per-target/per-cycle fixture,
   log and evidence roots, a finite configured concurrency ceiling (default 4; the provisional Review and all selected targets run at once, longest first), and the
   existing process-custody supervisor. Keep the Developer idle while jobs
   are active. A Review finding does not cancel live work. On explicit stop,
   controller shutdown or a classified provider/environment stop, cancel and
   reap owned children; persist cancelled receipts as neither pass nor fail.
4. Settle every launched job, verify Candidate identity is still T, and
   aggregate all offline/live failure signatures, Review findings and
   evidence references in one handoff. Classify from the controller dispatch
   ledger and typed failure evidence: pre-dispatch offline/evidence, an
   ordinary dispatched target failure as paid, explicit provider markers as
   provider, and custody/toolchain/account or unknown transport failures as
   environment pending evidence. Record each actual dispatch once; concurrency
   is a resource ceiling, not a spend count. Never infer provider failure from
   exit status alone.
5. Repair within the frozen offline, verification, provider-dispatch,
   no-progress and Developer-resumption ceilings. Track the set of unresolved
   failure signatures per round; a round that clears none or reintroduces a
   cleared signature spends the configured no-progress allowance. Stops name
   the class, remaining budgets, dispatch/spend ledger and concrete next
   action. Elapsed time is diagnostic and never a correctness gate (see Timing
   below); retain process-safety deadlines solely for custody and classify their
   termination honestly.
6. On a new tree T′, receipts and Review decisions for T do not authorize T′.
   Restart recovers only byte-verified settled receipts bound to the exact
   Candidate tree and frozen context/catalog; reuse only passed receipts for
   that identical binding and rerun unsettled work after custody recovery.
   Changed tree or relevant context invalidates the bound gate, live results
   and Review verdict. Review rework may continue the same Reviewer session
   with the T→T′ diff and open findings; if that session is unavailable, start
   a fresh full Review of the base→T′ diff.
7. On the final T, require all selected targets to have passed receipts, the
   full offline gate to pass, every scenario to be satisfied, no open blocking
   findings, a fresh independent Reviewer verdict bound to T, and a separate
   evidence-addendum turn in which that Reviewer checks the settled receipt
   digests/summaries and confirms or objects. A provisional Review never
   authorizes another tree or publication. Only the controller can join these
   records and enter guarded finalization/publication.

## Preserved feature scope

Keep the current `optimum` default route and explicit legacy routes. Preserve
its configured role profiles and route freezing: Opus 5.5 Medium Developer,
native Sonnet 5.5 Medium workers, independent Sol High Reviewer and Expert (named routes' Sol roles use `gpt-6.1-sol`, the settled owner decision),
Astra Low Shaper and Opus High auditor; optimum's Codex worker uses Luna Max.
Live targets and their prepares always run on the Build's selected route (the
route the Build was started with), never the Candidate's `default_route`; a
live target with no selected route fails. These are route-specific configuration and execution claims, not defaults for
general lifecycle fixtures. Each lifecycle run derives harness, model, effort
and native helper expectations from its selected frozen route. A Build started
with `codex` explicitly (Sol Developer and Reviewer, native Luna helpers) does
not prove Claude/Opus/Sonnet execution or change `optimum`. Keep Claude-specific required observations pending until
their own route-bound receipts exist. Keep the managed Codex 0.159.2 and Claude
Code 2.1.285 pins (tests read them from one source), actual runtime and session receipts, selected `live-native`,
`live-reviewer-rework` and `live-shape-to-build` observations, wrong-route and
missing-helper negative controls, and one independent final Review. Freeze the
resolved role/model/effort matrix for every admitted run. Native helpers have
non-overlapping ownership, concrete deliverables, completion checks and
blocker reporting; the parent integrates and remains accountable. No
cross-provider helper service or recursive fan-out.

Preserve required behavioral coverage while allowing tests to be renamed,
refactored, replaced or removed with changes disclosed to independent Review.
Baseline test identities are diagnostic, never a blanket acceptance gate.
The single complete `make check` gate includes formatting, compile,
analysis, the current non-live suite and Candidate-added tests, catalog
rehearsals, controlled prepares, generated-fixture validation and the focused
cold setup/dependency regression. Do not run a duplicate warm suite or the
standalone `cold-offline` suite for routine acceptance; keep that diagnostic
command available. Record stage and wall-clock measurements without arbitrary
100/300-second cutoffs. Exact receipt reuse checks tree, frozen context,
catalog, paths and hashes and fails closed on drift or tampering.

Keep the deterministic native-isolation oracle: distinguish bundled `.system`
content only through a provenance-bound inventory for the pinned runtime,
   verify planted forbidden sentinels remain absent and the project sentinel is
   present, and separately verify account/remote plugins are excluded (including
   one real plugin-enabled-account observation, run in a disposable
   `CODEX_HOME` so the shared scope is never written; there is no observer wait). An unclassified name fails the
   oracle as unsupported/unproven until its provenance is established; it is
   neither silently allowlisted nor called leakage without evidence. Never
   accept self-reported absence. Preserve process identity and
signal evidence, descendant cleanup, unrelated-process negative controls,
per-target cancellation/reaping, independent package custody, read-only Review,
compact integrity-bound evidence. Publication size is diagnostic; remove the
arbitrary 5 MiB/file and 10 MiB combined correctness gates. Do not weaken protected paths, verification
authority, required targets, review independence or assertion strength.

## Recovery and publication

Keep one recoverable Candidate code state and a compact recovery pointer to
verified implementation/evidence. Failed transcripts and superseded patches
stay outside the Intent. Missing or mutated recovery refs, stale receipts,
budget exhaustion and ambiguous Candidate identity stop explicitly. A terminal
admitted failure records its evidence/class before atomically returning the
selected Approved package to Draft; continuable interruptions keep frozen
custody. Reapproval retains failure history for diagnosis; repeated signatures alone do
not prohibit a new repair approach.

Finalization creates the Complete package, summary and concise evidence only
from frozen Approved bytes and controller receipts, validates review/receipt/
reference snapshots and the exact staged tree, and commits only through the
guarded controller path. Publication fast-forwards only the unchanged admitted
branch from a clean control checkout and performs the established cleanup.
No Developer commit/push or manual mutation of tracking evidence can impersonate
acceptance.

This remains one existing Intent with all 14 identities. Build-system-fixes
lands on MacBook first; fix-shaping follows on that engine. Preserve both kept
Candidates. See `EXECUTION.md` and `recovery.yaml` for the retained evidence.

## Accepted flexibility correction — Almir, 2026-09-29

Almir explicitly authorized finding and fixing/removing brittle checks in this
same Intent after cycle5 passed all1,801 tests but failed baseline-name
preservation. This decision supersedes older blanket preservation language.
Models may revise implementation, affected files and tests to satisfy the
actual contract. Unexpected implementation changes require disclosure and
independent assessment, not automatic rejection solely for deviating from a
shaping prediction. Do not freeze mistaken implementation assumptions as user
requirements.

Audit offline acceptance, retry/progress controls, path guards, evidence
readers, publication packaging and recovery. For each blocking rule,
identify the concrete failure it prevents. Remove arbitrary names, counts,
size and elapsed-time proxies where they reject valid work; use diagnostic
reporting or reviewer judgment instead. Keep actual failing checks, missing
required behavioral proof, unsafe process or credential access, active-owner
conflicts, corrupted evidence, unreviewed code and unauthorized external
actions blocking. Preserve user-configured resource limits; surface exhausted
budgets as recoverable decisions, never counterfeit success or silently reset
spent work. Evidence bookkeeping must recover legitimate controller-owned
transitions without misclassifying them as external tampering.

Record concrete changes and remaining justified blockers in the maintained
Build workflow. Do not add another prerequisite Intent or another qualification
campaign. Verify combined changes, then selected live checks and independent
Review concurrently, followed by final acceptance and publication.

Almir clarified the packaging goal: the Intent is a concise contract measured
in kilobytes, not megabytes. Removing arbitrary code-publication caps must not
normalize bloated packages. Store transcripts, recovery patches, historical
failures and bulk runtime evidence outside the Intent; retain only concise
current decisions, acceptance criteria and verifiable references. Report
contract size and unnecessary duplicated content before admission without
inventing another unsupported numeric acceptance cutoff.

Validation placement (Almir, 2026-09-29): report correctable contract size,
structure and feasibility problems during shaping and before Build admission.
Do not defer Shaper-owned mistakes to an expensive final gate where the
Developer cannot change frozen inputs. Finalization checks accepted code and
required evidence integrity, not new contract-packaging requirements. Where a
condition can change during execution, preflight predictable causes and retain
only the necessary final check; failures must identify the responsible repair
phase and preserve implementation for continuation.

Concrete plan correction: optional scenario.tests names and predicted path-owner
mappings are advisory and Reviewer-visible; required proof.offline evidence
and every selected verified_by target remain binding. Normalize equivalent
verified_by ordering/duplicates. A scenario may select multiple live targets
when needed; keep its primary paid proof and require real receipts for every
additional selected target. The reviewer assesses actual behavioral coverage,
including renamed/deleted/replaced tests disclosed by the offline receipt.

Audit-driven recovery completion: persist an exact acceptance/publication
transition before the irreversible Git update; after interruption reconcile
the observed published commit and retained accepted evidence, finishing the
ledger without rerunning paid work or calling an unpublished result successful.
Distinguish pre-publication refusal from post-publication bookkeeping failure.
Recover stale write ownership without admitting a second active writer.
Validate the
complete unique selected offline/live receipt set, not just whichever receipts
happen to be present.

Small shared shaping corrections in this repair: preserve all unanswered
questions across repeated headings; consequential unanswered human choices
remain pending regardless of elapsed time; allow root inspection alongside
helpers; distinguish behavioral constraints from Developer implementation
freedom; keep current decisions concise and bulk conversation history outside
the contract. The broader fix-shaping and context-integration Intents keep
their existing ownership and prerequisite order.


### Remove unused standalone context tool (Almir, 2026-09-29)

Almir explicitly requested complete removal of `kogen-ctx` in this same repair. Remove the native crate, Elixir launcher/Mix build task, dedicated tests/fixture, Cargo verification stages, exclusive Rust pin, ignore entry and current setup/MCP documentation. Preserve ordinary source discovery, role prompts, Build tracking/evidence and completed historical Intent records. No replacement context implementation belongs in this Build. The separate iCloud `plan/CONTEXT.md` owns the full future shaping handoff, pending user product decisions; do not revive the earlier split context queue. The check must run its remaining complete suite without requiring Rust/Cargo or the removed tool. Measured warm Cargo commands totalled 476ms and overlapped compilation; no unsupported Build-time saving is promised.


### Route-aware lifecycle verification (Almir, 2026-09-29)

General live Reviewer-rework and Shape-to-Build fixtures must exercise the selected frozen route, deriving harness/model/effort/helper expectations from its resolved configuration. Do not hardcode optimum/Opus/Sonnet into general lifecycle acceptance. Keep optimum default/profile configuration coverage separate and distinguish model-specific native routing observations; success on Codex does not claim Claude execution. A newly selected Codex-only run must not dispatch Claude through a hidden fixture default. Preserve independent Review, same Developer resume, actual helper routing and complete lifecycle proof. The interactive Shape driver must wait for actual turn/Stop-audit completion before closing the session; filesystem artifacts alone are insufficient and Ctrl-C must not preempt the auditor.


## Build-fix inclusions (Almir, 2026-09-30)

Almir directed that this contract include everything fixed during Build 1z-a1kMc5SVcWz2DAO7dMgIe, as reconciled to the committed code on 2026-09-30 after the operator phase API was removed. The Candidate implements, and the scenarios state:

- **Runtime pins and models:** managed Codex 0.159.2 and Claude Code 2.1.285, read by tests from one source. Named routes' Sol roles use `gpt-6.1-sol` (settled owner decision).
- **Timing is diagnostic:** active elapsed time per phase, cycle and Build is measured and reported, with a warning past `build_time_nudge_minutes`. The Developer is nudged every `developer_turn_minutes` by interrupting and resuming the same session with a progress and narrow-scope prompt, is never stopped for duration, and nudges are not repair resumptions. No Build, turn or stage fails solely for elapsed time. The offline-gate hang guard fails a stage only after no output for a period, classified as a stall.
- **Live fan-out and retry:** finite concurrency ceiling (default 4). One same-tree retry for a plain paid live-target failure (catalog flag `same_tree_retry`); both attempts are recorded and shown to the Reviewer and in handoffs; a pass on retry is flaky and counts as no progress. Timeouts, cancellations and provider or environment classes are never retried.
- **Dispatch accounting:** initial fan-out capacity reserved before any start; each start logged at launch; the provisional Reviewer dispatch ledgered for every outcome; the Developer-resumption ceiling charged per repair handoff; jobs active at an accepted stop recorded as cancelled.
- **Codex isolation:** skill classification bound to the observed origin, duplicates keep every origin, a foreign same-name entry fails; a fresh operation's Codex state db is seeded against the 0.159.x TUI backfill timeout.
- **Offline gate:** independent stages run concurrently; rehearsal receipts bind their own test identities or the command is executed; isolated test pool is capacity-based (1.5 x schedulers, `KOGEN_ISOLATED_POOL` override); a shared-VM cwd/env mutation guard.
- **Publication and acceptance:** publication evidence binds an immutable record-version sidecar; the acceptance join enforces exactly one receipt per selected live target.
- **Live shape-to-build** runs a real Shape session, then drives the Build with `mix kogen.build`; the repair handoff carries the check's own failing output.
- **Budgets:** `max_developer_resumptions: 3`; `max_no_progress` is derived (outer + verification + offline resumptions), not set; live concurrency ceiling 4.
- **Route:** live targets and their prepares run on the Build's selected route, never the Candidate's `default_route`; no selected route fails the target.
