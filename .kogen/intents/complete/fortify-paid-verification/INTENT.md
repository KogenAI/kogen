# Own verification in the Build controller with Candidate-bound receipts

**Approved revision** (explicit Shaper approval, 2026-09-25; see `approval.md`).
*Historical note:* this package was reopened after a failed Build. An earlier contract,
which included the native target split, was approved on 2026-09-24 against main
`2909f557`. Build `G8XQmw8OuNa-fPqe0TlQ0p35` then stopped with `cannot_comply`
before Review. That approval does not cover this revision (see `approval.md`).
This is item 1 of the five-item roadmap in
`.kogen/runtime/shaping-followups/OVERNIGHT_HANDOFF_2026-09-25.md`.
Planning inputs: `.kogen/runtime/shaping-followups/SHAPE_PAID_VERIFICATION_FORTIFICATION.md`
and `.kogen/runtime/shaping-followups/archive/superseded-paid-verification/02-controller-verification-cutover.md`.

**Build order (Shaper-approved, 2026-09-25):** fourth, after
`bounded-reviewer-evidence`, `cross-harness-adversarial-roles` and
`shaping-preflight-audit`. On 2026-09-26 the driver moved it ahead of the
parked `shaping-preflight-audit` (a reordering; no scope moved). Risk `baseline-moves-before-build` requires a
baseline recheck before the Build.

**Revised by the driver after preflight (2026-09-25).** The Build preflight
was re-run against main `2909f557` and the designs of the three earlier
Intents. The scenarios now build on them: the Review ledger and reuse marks go
into the bounded review packet from `bounded-reviewer-evidence`, and
superseded objections keep working on controller cycles. The compatibility
fixture has no stand-in Reviewer to preserve (`cross-harness-adversarial-roles`
removed it). The inputs main's controller reads from the Candidate
(rehearsal traces, role prompts, the test-reliability ledger) are stated.
The new controller keeps writing the local Verification Record for the unedited
`live-reviewer-rework` audit, and its preflight stops requiring the Stop
script. `priv/kogen/test-reliability.yaml` is guarded for hash-only refreshes.
The full list is in `approval.md`.

**Driver re-preflight at 363c20af (2026-09-25/26).** `bounded-reviewer-evidence`
(22a2db95) and `cross-harness-adversarial-roles` (363c20af, landed without an
auditor role and with `default_route: claude`) are on main.
`shaping-preflight-audit` is parked for the Shaper, so this Intent builds third,
on 363c20af, and depends on none of its code; aligning that Intent's rule checks
with this controller is recorded in its PARKED note. Changes: the Shape
fixture's evidence retention copies the whole tracking tree, including #2's
record-version sidecars (scenario `shape-to-build-retains-record-sidecars`, 13
scenarios in total); the Reviewer's output schema gains `ledger` only when a
ledger is supplied, on both harnesses (this Build's own Reviewer is Codex, bound
by main's `Verdict.schema/0`); `base_cache` never copies controller volatile
state; and the route and anchor text matches the landed code.

**How to read the scenarios.** They describe the controller this Intent
ships, which is the Candidate's code. Offline tests prove it, and so does the
nested fixture Build inside `live-shape-to-build`, which compiles the
Candidate. This Build itself runs under main's controller through the Stop v1
path. It leaves the Makefile, the catalog (with `check`) and the v1 Stop path
unchanged, and its own contract uses none of the new contract features.

## Problem

Build `btwokrNxL50md1z5Fb-GGYOO` (cross-harness roles) spent three verification
cycles, 430 s, 261 s and 388 s of paid time, re-verifying **the same Candidate**
(`69e499f375…`). Each cycle re-ran `check`, then the whole `live-native`
aggregate. Four of that target's five live cases passed every time. Only the Codex
compatibility case failed, with a provider turn timeout (exit 124). Stop cannot tell
targets apart inside an aggregate or reuse anything. Verification lives in a
harness Stop hook (`.codex/hooks/check.sh` → `stop_runner.py`) whose state the
controller only reads afterwards. See `evidence/investigation.md`.

## Outcome

1. **One verification authority, removed in two steps.** After each Developer
   turn ends, the parent Build controller (the trusted code the Build started
   with, never code loaded from the Candidate) computes the Candidate identity
   itself. It runs `make check` and the selected targets as child processes
   outside the Developer process tree, and writes the only context, state and
   history. It never gives a Developer-launched process a verification context.
   For every Build started under this controller, that is the only writer.
   **Bootstrap:** this Build starts under main's controller, which can settle
   only from Stop-written state. So `check.sh`/`stop_runner.py` and their Stop
   registrations stay for exactly one commit, reduced to a single path. They run
   only when an older controller supplies a v1 unified `KOGEN_VERIFICATION_CONTEXT`;
   otherwise they print `{"continue":true}` and do nothing. The no-context mode,
   which runs `check` and blocks, and the `KOGEN_TRACKING_CONTEXT` path are
   deleted. A follow-up Intent built under the new controller deletes the Stop
   scripts and registrations. That follow-up is its own small verification
   Intent, not yet shaped. It is not `cross-harness-adversarial-roles`. The new controller also explicitly removes
   `KOGEN_VERIFICATION_CONTEXT` and `KOGEN_TRACKING_CONTEXT` from every child
   environment, because main's Stop runner passes its context down to any nested
   fixture Build. This Build must itself reach automatic verification,
   Review and commit; a manual finish is not accepted. The PreToolUse gate guard
   stays. The new controller also becomes the only writer of the local
   Verification Record and its history (`Kogen.Check`), so existing readers such
   as the `live-reviewer-rework` audit keep working unedited. The Candidate's
   preflight stops requiring the Stop script, so the follow-up can delete it.
2. **Failed verification resumes the same Developer.** A failed cycle resumes the
   exact Developer session through the existing `resume_build_developer`. The
   resume names the failed target and its retained receipt and log paths, and it
   counts against `verification_retries`, never the outer allowance. Exhaustion
   stops the Build with the existing precedence. Every outer resumption still
   needs fresh controller verification before handoff or Review.
3. **Candidate-bound per-target receipts.** Each receipt records the target,
   status, exit code, Candidate id, attempt token, context digest, catalog digest,
   cycle, start and finish times, elapsed time, the output log path and digest,
   and the cleanup outcome. It also snapshots any target-evidence manifest, as
   today.
4. **Rerun only failed paid targets.** Within one verification context (one outer
   attempt), a later cycle always runs `check` fresh. It reuses a paid target's
   earlier *passed* receipt only when the Candidate id and catalog digest are
   byte-identical, and marks it as reused with the cycle it came from. Then it
   runs the failed target and any target not yet run, in catalog order. Any
   Candidate change reruns everything. A new outer attempt reuses nothing.
5. **This Build leaves the target catalog and Makefile unchanged.** Main's
   controller stops any Build whose `priv/kogen/verification_targets.yaml`
   changed after admission, so this Build can't use outcome 8 on itself.
   `live-native` stays as it is. The follow-up verification Intent then uses
   outcome 8 to split it, under this Intent's controller.
6. **Provider policy stays inside the target that owns it.** Kogen core has no
   provider-timeout config, provider classification or provider retry. The
   Codex compatibility owner drops its Stop-hook portion, which depended on the
   no-context Stop mode deleted here. Its turn budget and one fresh-fixture
   timeout retry are delivered first by `cross-harness-adversarial-roles`, and
   this Intent leaves them unchanged.

7. **No target is special by name** (scenario `no-special-gate-target`).
   `mix kogen.build` no longer requires `make check`. `verified_by` is the
   complete, explicit list of targets a scenario needs. It must contain at least
   one offline target and at most one paid target, together with their
   dependencies. The Build runs exactly the union of those lists. Offline
   targets run fresh every cycle. Receipts are one uniform list. Make stays the
   only runner.
8. **Verification can't be quietly weakened, and the Developer can still change
   tests and targets freely.** Freezing definitions is false comfort, because
   `make ci` can call a `mix ci` alias that the Developer then empties. Instead,
   trust comes only from the admission commit, the admission catalog, the
   approved Intent and controller code:
   - **Targets** (scenario `same-intent-catalog-change`): the catalog is no
     longer byte-frozen. An Intent may add targets and select them
     (`catalog_changes.add`). Selected targets must exist in the Candidate.
     Anything else a Candidate changes in the catalog goes into the ledger.
   - **Proof tests** (scenario `controller-runs-proof-selectors`): the
     controller runs each scenario's proof tests itself. For new behaviour
     (`proof.base: fail`), those tests must also fail on the admission commit,
     with base's own runner and only the Candidate's test files overlaid. That
     catches empty, `assert true`, skipped and `:live`-hidden proofs. For
     preservation (`proof.base: pass`), base's version of an edited test must
     still pass on the Candidate.
   - **Everything else** (scenario `verification-surface-ledger`): every
     changed test or runner file, including files outside `affected_paths`,
     goes to Review with its diff. The Reviewer must mark each one `justified`
     or `weakening`, and code enforces that. Review also gets a report of
     base's test suite run against the Candidate. `weakening` blocks and goes
     back to the Developer. Nothing goes to Jev.
   The integrity fields live in the admission catalog, which this Build can't
   change. So this Intent ships and tests the mechanism, and the follow-up
   Intent switches it on for Kogen. Existing contracts, including this one,
   keep validating and are labelled `unproven-on-base`.
9. **Shaping selects paid targets less often** (scenario
   `offline-first-target-selection`). Kogen's shared Shaping prompt selects a
   paid target only for a provider-only observable. It drops the "even when
   their live test files are unchanged" rule. Kogen's README gains the
   repository's own policy: orchestration is offline-only, paid targets are
   reserved for native harness and runtime boundaries, and an Intent selects at
   most one paid target unless the Shaper accepts more.
10. **Kogen's README explains two-step self-hosting changes** (scenario
    `self-hosting-two-step-guidance`). A change that removes something the
    running Build depends on follows expand and contract, like a zero-downtime
    database migration. The README lists those inputs with their source
    locations. This guidance is Kogen-only; the shared Shaping prompt doesn't
    get it.
11. **This Intent runs the two live tests it edits.** Scenario
    `controller-owns-verification` selects `live-shape-to-build`: a real Claude
    Code session through the new controller's fail, resume, pass, Review and
    commit loop. Scenario `stop-free-compatibility-fixture` selects the
    still-unsplit `live-native`, the real Codex runtime in the Stop-free
    fixture. Everything else is proved offline.
12. **Retained Shape-fixture evidence resolves after cleanup** (scenario
    `shape-to-build-retains-record-sidecars`). The live Shape test retains each
    nested Build's whole tracking directory (record, record-version sidecars,
    review packets, controller verification files) through one support
    module, the gap that failed Build `o-DlRi` in the Reviewer-rework fixture.

## What this Intent adds, and its caller and proof

| Addition | Caller in this Intent | Proof |
|---|---|---|
| `lib/kogen/build/verification_runner.ex` | `Kogen.Build` after each Developer turn | controller_verification_test, verification_ownership_lifecycle_test, `live-shape-to-build` |
| `lib/kogen/build/target_evidence.ex` (changed) | verification runner (manifest on pass and fail) | target_evidence_test |
| `lib/kogen/build/catalog_change.ex`, `catalog_changes.add` | admission and each cycle's catalog check | catalog_change_test, intent_test |
| `lib/kogen/build/base_workspace.ex`, `proof.base`, catalog `verification_surface`/`focused_runner`/`base_cache` | controller proof-selector runs | proof_selector_verification_test (fixture catalog) |
| `lib/kogen/build/ledger.ex`, `lib/kogen/build/review.ex`, verdict `ledger` field and per-launch schema | handoff report, review packet, Reviewer launch on both harnesses | verification_surface_ledger_test, check_settlement_test, review_packet_test |
| receipt reuse (`reused_from`) | verification runner | verification_reuse_test |
| `test/support/live_tracking_retention.ex` | both retention sites of `live_shape_to_build_test.exs` | build_evidence_test, `live-shape-to-build` |

The catalog integrity fields, `proof.base` and `catalog_changes.add` are consumed by this controller and
proved on fixture repositories. Kogen's own catalog cannot adopt them in this Build, because main's
controller byte-freezes it (D9); the Shaper-approved follow-up (ROADMAP 10) switches them on.

## Outcome walkthrough and challenge

- **Start:** a clean `main`, with `live-shape-to-build` and `live-native` as the
  only paid targets, and `verification_retries: 2`. Main's Stop runner reruns
  `check` and both paid targets every cycle. Recorded medians are about
  1 + 4 + 4 minutes; `live-native` can take up to 10.
- **Turn 1 ends:** the parent controller verifies. `check` and the connected
  lifecycle target settle, receipts are retained, and any failed target is
  reported to the resumed Developer with its receipt and log path.
- **Developer ends unchanged:** the next cycle runs `check` fresh and reuses
  only a paid target that passed on the same Candidate and context.
- **Developer edits a file:** the next cycle runs everything.
- **Third failure:** verification is exhausted and the Build stops.

- **Inherited context:** any process started under main's v1 Stop runner
  inherits its context. The new controller removes the context from every child,
  so a nested Build can never write to an outer Build's state.
- **This Build's own finish:** the Candidate leaves the Makefile, catalog, Stop
  scripts and registrations in place, so main's controller settles, reviews and
  commits it automatically.

- **Later Build with a new target:** it declares `add: [x]` and selects `x`.
  The Developer adds `x` and its test. The controller runs `x`, then runs the
  scenario's proof tests itself: red on a clean export of base with base's
  runner, green on the Candidate.
- **Later Build that splits a target:** the follow-up declares the narrow
  targets in `add` and selects them. Removing `live-native` shows up in the
  ledger, and the Reviewer justifies it against the split scenario.

**Challenge:** a Developer could empty a proof test, tag it `:live`, or empty
the `mix ci` alias behind a gate. The first two pass on base, so the
controller-run red check rejects them. The third can't fool the red run,
because it uses base's runner. It also reaches Review as a runner-class ledger
item that must be marked `justified` or `weakening`. A test written to detect
which tree it runs on is left to Review. That limit is recorded.
Similarly, an implementation could pass every offline test but change the
catalog, or omit the context scrub. The first stops this Build before Review, as
G8XQmw8OuNa-fPqe0TlQ0p35 did. The second lets the nested fixture write to the
outer state. The guarded paths exclude the Makefile and catalog, and a
planted-context control covers the second.

**Also wrong:** requiring `make check` at admission; implicitly adding
targets; accepting an undeclared catalog change; accepting an added target that
passes on base.

**Wrong implementations that must fail:** rerunning every paid target on an
unchanged Candidate; reusing a pass across a Candidate change or across outer
attempts; skipping `check`; reading a Candidate-writable state file as success;
letting Stop run checks or block when no v1 context is present; passing an
inherited context to a child; changing the Makefile or catalog; loading the
verifier from the Candidate; putting
provider-timeout retries in the controller; treating an owner's `timed_out` as a
pass.

## Accepted decisions (Shaper)

- 2026-09-25 continuation, fourth turn: Kogen-only README guidance for
  two-step (expand and contract) self-hosting changes, not a change to the
  shared Shaping prompt.
- 2026-09-25 continuation, sixth turn: all verification-integrity work goes
  in this Intent ("everything and anything about that goes in"). The Shaping
  Controller adopted the expert design (`evidence/verification-integrity-design.md`)
  and settled its open points: `proof.base` is required for new contracts and
  legacy contracts are labelled; preservation selectors get the base-bytes code
  check; the base suite runs on the Candidate as a Review report, not a gate;
  `weakening` goes to Review rework; base-fingerprinting tests are left to
  Review. This supersedes target-level red-on-base, recipe freezing, the owner
  partition, `red_on_base: exempt` and `remove`/`replaced_by`.
- 2026-09-25 continuation, third turn: Make isn't required ("why is even make
  part hardcoded?"). Reorganizing tests that already pass is exempt from red on
  base. This Intent needs only offline proof, and Shaping should require live
  tests less, at least in Kogen. The Shaping Controller designed the `command`
  field, the exemptions, and the prompt and README policy, and dropped the paid
  `live-shape-to-build` run.
- 2026-09-25 continuation, later turn: remove the hardcoded `check` gate
  ("we gotta fix that as part of this"). Let an Intent add a target and require
  it in the same Build, with guardrails the Shaping Controller designs ("write
  those rules, guardrails ... make it good"). The Shaping Controller chose
  declared `catalog_changes`, frozen retained recipes, red on base through a
  `git archive` export (no worktree Intent needed), exact owner partitioning
  for replacements, and returning failures to the same Developer.

- 2026-09-25 continuation: scope is limited to controller-owned verification,
  Candidate-bound receipts, a fresh `check`, same-Candidate failed-target reuse
  and the Codex owner's one fresh-fixture timeout retry. There are no Makefile
  or catalog changes. Automatic Review and commit go through the existing Stop
  bootstrap path. (Its "no new Intent" constraint was lifted in the fifth turn.)
- 2026-09-25 continuation, fifth turn: the roadmap-size constraint no longer
  applies ("now we're back to regular development"). Run the edited
  `live-shape-to-build` here ("a. yes, we should edit and run it here"). Run
  the edited Codex compatibility owner through `live-native` here too. Make
  stays the only runner ("we can keep the make hardcoded"). The Stop removal and
  `live-native` split move to a separate follow-up verification Intent.
- Default outer allowance (2).
- Reuse happens only within one verification context and only for a
  byte-identical Candidate. A fresh `check` is mandatory every cycle.
- Provider timeout and retry behaviour belongs to the project-specific target
  owner, not Kogen verification. The Codex owner's retry and turn budget moved
  to `cross-harness-adversarial-roles` (Shaper-approved order, 2026-09-25).
- Two-step Stop removal. The Stop scripts stay only so this Build, started under
  the old controller, can finish automatically. The follow-up verification
  Intent removes them.
- Verification runs in the parent controller, not in Candidate-authored code.
- `cross-harness-adversarial-roles` (approved, unbuilt) will be re-shaped
  separately; this Intent does not touch it.

Historical (superseded 2026-09-25): the approved 2026-09-24 contract also
removed `live-native` with no alias in this Build. That became impossible under
main's controller, as shown by `G8XQmw8OuNa-fPqe0TlQ0p35`.

## Non-goals

- Any change to `Makefile` or `priv/kogen/verification_targets.yaml`, and any
  change to `priv/kogen/test-reliability.yaml` other than the `source_sha256`
  refresh of edited cataloged tests through
  `scripts/check/refresh_test_reliability_sources.py`. That includes the native
  target split, removing `live-native`, and ledger `target` strings. These
  belong to the follow-up verification Intent.
- Editing the `live-reviewer-rework` owner or its support files
  (`test/kogen/live_reviewer_rework_test.exs`,
  `test/support/live_reviewer_rework_fixture.ex`,
  `test/support/live_rework_audit.ex`). This Intent doesn't run that target.
- Deleting the Stop scripts and registrations, and paid proof of the Stop-free
  Codex compatibility fixture through a narrow target (follow-up verification
  Intent).
- Any target runner other than Make.
- Freezing target definitions or transitive runner files. Permission stays in
  `may_change_guarded_paths`, and weakening is caught by the controller-run
  proof checks and the Review ledger.
- A paid red-on-base run. Provider-backed added targets are proved through
  their rehearsal tests as file selectors.
- Mutation testing, and switching integrity on for Kogen's own catalog (the
  follow-up Intent does that).
- Controller-level per-target timeout or cancellation policy. Hung targets behave
  as they do today.
- Generic provider preflight, per-turn progress diagnostics, and failure classes in
  Kogen core.
- Reusing paid receipts across outer attempts or Builds.
- Controller generation freezing (`drafts/bind-controller-generation`), candidate
  workspaces (`isolated-candidate-workspace`), process-tree shutdown on
  Build exit, cost accounting, offline failure aggregation, and failed-Build return
  to Shaping.
- Editing any other Intent package, including `cross-harness-adversarial-roles`.
- Changing Jev, Review, handoff-report or review-packet semantics (beyond listing
  reused receipts and adding the bounded ledger), model routing, the default
  route, or native launch flags.

## Retry after Build uaYa_xCH (2026-09-26, driver)

Start from branch `backup/fortify-paid-verification-fix4`. It holds the previous Candidate plus the
one-clock Verification Record fix (evidence/build-failure-uaYa_xCH.md), and it already passes `make check`
and `make live-shape-to-build`. Restore its files with `git diff --name-status HEAD
backup/fortify-paid-verification-fix4` and `git show backup/fortify-paid-verification-fix4:<path>`; don't
merge or check out the branch. Then review the result against every scenario. Don't re-implement from scratch.
