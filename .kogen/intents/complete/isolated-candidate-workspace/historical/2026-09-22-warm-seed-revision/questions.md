# Open questions

## 2026-09-23 reshape toward parallel-ready Builds (pending Shaper answers)

The Shaper supplied `.kogen/runtime/shaping-followups/SHAPE_PARALLEL_READY_BUILDS.md`
in this visit: per-Build worktrees with concurrent Builds of different Intents
(no global `.kogen/build.lock`), serial publication that refuses when `main`
moved, and named routes selectable per session. It explicitly permits not
inheriting this Draft's complexity and splitting if it does not fit one Build.
The current checkout `6cdb2912` (pluggable harness) differs from the recorded
baseline `c1f08532`; reassessment is required and no baseline update has been
decided. Findings: the saved `harness.ex` payload is the pre-`6cdb2912`
monolithic Codex harness (applying it would revert the pluggable harness);
30 of 41 saved files are unchanged at HEAD; routes touch one config parser
(`lib/kogen/intent.ex`), `Harness.open`, both mix tasks and ~30 tests.

Settled in this visit (see `decisions.md`): split A (routes, fresh Shape,
first) / B (this Draft); clean control checkout required at publication;
saved implementation is reference only; pinned engine per Build; reshape
against `6cdb2912`.

Intent A (`named-routes`) landed as `5af11273` on 2026-09-23. Its Build
spent the whole outer allowance on handoff bookkeeping (attempt 0 malformed
final JSON; attempt 1 risk `test-reliability-catalog` scenario_ids differed from
the Approved risk; attempt 2 accepted), not on the feature. Shaper decided
(“maybe we do a new Intent that actually addresses this issue?” / “give me an
intent file … for fixing the full handoff thing - all the failures”): a
handoff-hardening Intent is shaped and built before B1, from
`.kogen/runtime/shaping-followups/SHAPE_HANDOFF_HARDENING.md`, which catalogs
every retained Developer handoff failure. Reshape B1 after it lands.
The committed config names routes `claude` and `codex`; the Shaper had asked
for `claude` and `chatgpt` — confirm the intended name.

For B2 (not B1): the older unapproved Draft
`.kogen/intents/drafts/bind-controller-generation` (shaped against `05133eff`,
Codex-era) addresses the same controller-stability problem as this visit's
pinned-engine decision, by force-loading modules and holding admitted resource
bytes in the controller VM with validated projections. B2's Shaping must
reconcile the two into one design (pinned recompiled engine copy vs in-VM
generation) rather than build both; see
`evidence/engine-stability-probe-2026-09-23.md`.

Settled later in this visit: B split into B1 (this Draft) and B2 (fresh Shape). Original proposal: Controller proposal: B1 = Candidate worktree isolation,
still one Build at a time (global lock kept; hooks resolve from the unchanged
control checkout), publication from the Candidate with a compare-and-swap on
`main` and clean control, paid `[check, live-shape-to-build,
live-reviewer-rework]`. B2 = per-Build lock/state, concurrent Builds of
different Intents, same-Intent refusal, pinned engine, serial publication lock,
multi-Build output. Consequence: B1 alone already matches the scope that failed
repeatedly as this Draft; adding concurrency and the engine to the same Build
increases rework risk on the live targets.


Current revision, after failed Build `181SwyyMv5aW2U838Wh8xXIt` and requested
Fable/Luna investigation: Draft, pending fresh approval. No new human product
choice was needed for the engineering repairs
in `repair-plan.md`; the existing basic-isolation scope and source-reuse choice
remain. The terminal-process failure's cause is still an engineering unknown,
not a settled flakiness/timeout diagnosis. The cloning uncertainty was resolved
by the direct native/HFS+ probe; `cp -c` cannot enforce clone-or-fail. The latest
cycle results and remaining verification limits are recorded in
`evidence/latest-build-reconciliation.md`. Earlier approvals below are historical.

The maintained attempt semantics settle the audit count: invalid handoff
correction consumes an outer resumption in the same Developer session. The
controlled one-Review-rework route must also support a permitted intervening
handoff correction, without increasing allowances or inventing intra-attempt
correction counters. Helper/module placement is implementation freedom, not a
human question. The 41-path package snapshot closes the clean-start recovery
input gap without moving Git refs, consuming a stash, or changing the baseline.

No unanswered product choice currently blocks the basic-isolation contract. On 2026-09-22 the Shaper explicitly narrowed this Intent to one active Build in an isolated Candidate. Concurrent Builds, stopped-Build continuation, and integration with newer main are parked in separate follow-up briefs; they are not approved backlog or implementation requirements here. This scope decision supersedes the earlier proposal to amend the seven scenarios for concurrency.

Settled future interface: `mix kogen.build <slug>` should detect existing work and continue eligible work, rather than requiring a separate resume command. Eligibility, exhausted allowances, unavailable sessions, authority changes, and automatic integration/repair limits remain questions for those future briefs. The partial interface choice does not authorize restarting exhausted attempts, adopting arbitrary failed directories, widening scope, or inventing a replacement Developer session.

Settled boundary from the Shaper: investigation, bringing current main into a Candidate, conflict resolution, and repairs all happen in the Build's owned worktree. Never install unverified changes onto main and fix them there. If main has not advanced and the Candidate's existing verification and Review are still valid, publication needs no artificial merge or duplicate test run. A conflict-free merge that changes the tested combination still requires fresh verification and Review.

`developer-experience.md` distinguishes this slice's actual scope from the parked proposals and links their unresolved choices. The previous separate resume-command proposal is withdrawn. Future changed-main integration is not needed to complete this Intent: this slice refuses publication when its admitted main ref no longer matches.

The Shaper explicitly chose the current Intent identity and `c1f08532` baseline while preserving the original workspace outcome. The earlier blanket restriction treating every failed implementation or stash as historical-only is superseded by the 2026-09-22 instruction to preserve and continue all 38 files in checkpoint `913ba174bffd864e0940c49d36d9e5d022333565`; see `developer-recovery.md`. The older package and commit `97109bf9` remain historical-only. Reusing these specifically authorized source bytes neither accepts them nor resumes an exhausted Build.

The Shaper subsequently rejected compulsory clean compilation on each workspace creation and selected filesystem-native APFS clone-on-write warm seeding. The final clarified allowlist is exactly required `deps/` and `_build/`; no credentials, homes, broad caches, locks, sockets, receipts, logs, runtime/session, verification/tracking, or mutable controller state are cloned. Normal Candidate-rooted Mix validation and incremental compilation still rebuild every invalidated artifact. Admission fails when safe cloning, stable required seeds, or sufficient space are unavailable; eager byte-copy and automatic cold-build fallbacks are not accepted. The cold recipe remains a separately verified readiness/recovery control.

The implementation may choose internal module boundaries, but it must preserve the current reliability consumers and selected target ownership. Two approved revisions failed Build and were returned to Draft; both approvals remain historical evidence only.

The accepted private-HOME boundary remains: tracked `mise.toml` travels with the physical Candidate and installed mise data is an immutable admitted input. The later live failure proved that rejecting every seed symlink contradicts required warm `_build` input. The corrected policy admits only ordinary relative Mix-shaped links contained in the corresponding project tree and outside `.kogen/runtime`; absolute, dangling, escaping, runtime-targeting and retargeted links fail closed.

The Shaper directed that scenario-focused tests be identified during Shaping and run iteratively by the Developer while coding, before Stop runs the authoritative full suite and selected paid targets. `proof.offline` is the maintained causal map; `developer-testing.md` gives the working loop and focused commands. The installed prompt permits focused non-gate tests throughout development, separately from its two fixed controller-readiness points. Real provider execution remains controller-owned.

Readiness is not established by YAML/plan validation. The latest actual live runs failed, the corrected implementation has not passed those routes, and an existing `_build/lib/kogen/priv` link into an old runtime worktree still violates the amended seed policy. See `evidence/readiness-and-parallel-work.md` for source locators, remaining prerequisites, and measured verification durations. The earlier conversational assurance that the package was ready did not establish end-to-end success.

The later requested parallel diagnostics passed 234 existing offline tests but
reproduced the standalone reviewer loader failure and valid-contained-link
admission rejection. Those green tests do not contain all required new controls;
`evidence/focused-diagnostics-2026-09-22.md` records commands, counterexamples and
limits. No wording change can guarantee every future test passes. This is an
implementation contract, not a verified working Candidate. `approval.md` owns
the current Draft/approval state; the diagnostic limitations remain unchanged.
