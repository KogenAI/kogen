# Approval

## Current approval (2026-09-26)

The human Shaper explicitly approved this Draft with "I approve" in the continuation Shaping
conversation on the `claude-dominant-adversarial-codex` route (recorded 2026-09-26T06:50:54Z).
It covers Intent `01a0c467-54c1-7a5a-9cee-58d70920d780`, `isolated-candidate-workspace`, as
reshaped against `main` at `98ebcfb2`: ROADMAP order 5, ID 7 (EXE-01, SEC-01, BLD-12),
14 scenarios, 15 risks, targets `check`, `live-reviewer-rework` and `live-shape-to-build`, and
the unchanged guarded paths. This moves the package to
`.kogen/intents/approved/isolated-candidate-workspace/`. Approval is not proof that a Candidate
passes, and it grants no source, test or configuration write beyond what a Build of this Intent
performs within `may_change_guarded_paths`. The sections below are history.

## Historical batch approval (2026-09-25)

The human Shaper explicitly approved the 2026-09-25 batch, including this
Intent, in the driver conversation: "so yeah, I approve: 1. bounded-reviewer-evidence
2. cross-harness-adversarial-roles 3. shaping-preflight-audit
4. verification-fortification 5. isolated-candidate-workspace", and confirmed:
"that should count as my explicit approval". The Shaper also delegated every
technical decision: "you gotta make sure all the intents are ready to build tho
… utilize jev, Astra medium, Sol high … I approve whatever you guys decide! so
you can build, drive this without me … make sure you don't stop for any
bullshit".

Scope of the approval: ROADMAP order 5, ID 7, "Isolated Candidate workspace: a
worktree, harness home and credentials per Build; Shaping keeps working during
Builds", with one lifecycle target (`live-shape-to-build`). It covers Intent
`01a0c467-54c1-7a5a-9cee-58d70920d780`, `isolated-candidate-workspace`, as
re-shaped on 2026-09-25 against `main` at `2909f557` on the assumption that
Intents #1 to #4 have landed: 10 scenarios, 9 risks, verification `check` +
`live-shape-to-build`. BLD-12's launch-time write boundary is outside this
approval and is proposed as its own ROADMAP row.

Build order: fifth, after `fortify-paid-verification`. The driver re-checks the
package against the then-current `main` (see the READINESS file) and moves it
to `approved/`; a contradiction needs a revision and a fresh record here.
Approval is not proof that a Candidate passes, and it grants no source, test or
configuration write beyond what a Build of this Intent performs within
`may_change_guarded_paths`.

The 2026-09-24 approval below covered the B1 contract whose Build
`cFnHwg7P2oNe1wMMnK7jxeMH` failed; it does not cover this revision.


## Driver re-preflight at 363c20af (2026-09-25)

Recorded by the driver session under the Shaper's delegation. The Shaper's
words (2026-09-25, driver session): "you don't need me for anything, you can
do everything yourself … I approve everything", and "NO STOPPING THE BATCH …
YOU FIX AND RESHAPE AND SHIT UNTIL ALL GOES WELL". Scope is unchanged:
ROADMAP order 5, one lifecycle target (`live-shape-to-build`).

Baseline: main `363c20af202c8702d76ddcb1dadcf6a21996779c` (#1 22a2db95 and #2
363c20af landed; #2 has no auditor role and keeps `default_route: claude`),
with `shaping-preflight-audit` and `fortify-paid-verification` assumed landed.
Id, slug, title, scenario ids and paid target are unchanged. Changes:

1. `per-build-harness-home`: on a hybrid route, `mix kogen.expert` (run by the
   Developer from the Candidate) uses the Build's binding and harness home;
   the Shaping auditor from #3 goes through the same Claude environment
   builder. `lib/mix/tasks/kogen.expert.ex` is guarded; `harness_role_test.exs`
   is a selector. `RootProfileAudit.sessions_root/3` is named as #2 left it.
2. `candidate-creation`: the Candidate never receives `.kogen/build.lock` or
   other controller volatile state (build-failure lesson 13).
3. `candidate-routing`: `Harness.open_roles/3` takes its root explicitly;
   review packets and record-version sidecar locators stay control-relative.
4. `shape-to-build-retains-record-sidecars`: rewritten for this Intent. #4
   fixes the Shape fixture's retention; this Intent keeps what it retains
   control-side and resolvable after the Candidate worktree is removed
   (lesson 1).
5. Anchors re-read at 363c20af (`verification_policy.ex:14,59-85`,
   `harness/claude.ex:26,164-165`, `codex/environment.ex:227-303`,
   `lifecycle_test.exs:781-791`). Stashes are named by SHA. The `unrun-live-targets`
   risk is corrected (live-general runs no Build). `questions.md` uses the
   Shaping-audit section grammar.

Validators and audits for this revision are in
`evidence/repreflight-2026-09-25-363c20af/`.

## Shaper decision: the write boundary stays here (2026-09-25, late)

The Shaper was asked whether BLD-12's launch-time write boundary should stay in
this Intent or become the split ROADMAP row 7b. The Shaper's answer (driver
session, about 21:45; `plan/BATCH-REPORT-2026-09-25.md`): **"Keep it in #5"**.
Build roles and helpers must be physically unable to write outside their Build's
worktree, enforced by macOS. Row 7b is withdrawn. The sentence in "Current
approval" above saying BLD-12's boundary "is outside this approval" is superseded.
The approval's scope is ROADMAP order 5 with its full feature list (EXE-01,
SEC-01, BLD-12).

The driver's shaping subagent folded the boundary in under the Shaper's
delegation ("I approve whatever you guys decide", "I approve everything"). It
added outcome 13 and scenarios `role-write-boundary`, `write-boundary-fails-closed`
and `codex-roles-inside-boundary`. It also selected the existing paid target
`live-reviewer-rework` next to `live-shape-to-build`, for the one Codex
provider-only observable (D8; `questions.md` R10). Id, slug and title are
unchanged. The package now has 14 scenarios and 15 risks.

## Historical approval of the 2026-09-24 B1 revision (superseded)

The human Shaper explicitly approved this reviewed B1 revision with "I approve"
in the 2026-09-24 Claude Code shaping conversation (recorded 2026-09-24T05:48:08Z). This approves
Intent `01a0c467-54c1-7a5a-9cee-58d70920d780`, `isolated-candidate-workspace`, as
reviewed: 8 scenarios, 6 risks, reshaped against `main` at `5b44ceb4`, with
verification `check` + `live-reviewer-rework` + `live-shape-to-build`. It
includes the Candidate list/remove commands; prune and orphan cleanup are parked
in `SHAPE_CANDIDATE_PRUNE.md`. This authorizes moving the package to
`.kogen/intents/approved/isolated-candidate-workspace/`. Approval is not proof that
a Candidate passes, and it grants no source, test or configuration write.

## Historical Draft state during the 2026-09-24 reshape (before approval)

Reshaped as B1 on 2026-09-24 from the Shaper's brief
`SHAPE_B1_ISOLATED_CANDIDATE.md` against `main` at `5b44ceb4`. No current
approval applies. Every approval below is historical and covered earlier
revisions that no longer exist as a contract. Fresh explicit approval of this
reviewed revision in a Shaping conversation is required before moving it to
Approved. This reshape changed only the package; it made no source, test or
configuration edits and launched no Build.

## Historical Draft state before the 2026-09-24 reshape


The Shaper requested “run cheaper subagents to fix the intent” after failed
Build `181SwyyMv5aW2U838Wh8xXIt` and the latest Fable-high diagnosis. This same
package is reopened under `drafts/isolated-candidate-workspace/`. That request
does not approve the revision. No current approval applies; fresh explicit
approval of the reviewed revision is required before another move to Approved.
This revision changes only the package and preserves unverified source inputs;
it performs no production/test/configuration edits or Build launch.

## Historical approval before Build 181SwyyMv5aW2U838Wh8xXIt

The following is the prior approval statement, preserved as historical evidence,
not authority for this amended Draft:

The human Shaper explicitly approved this reviewed Fable-high revision with
“I approve.” Recorded at 2026-09-22T11:06:18Z. This approves Intent
`01a0c467-54c1-7a5a-9cee-58d70920d780`, `isolated-candidate-workspace`, as reviewed:
seven scenarios, five risks, the focused Developer test map, `repair-plan.md`,
and the required preservation/reuse of all 38 saved implementation files plus
the newer fixture normalization. The guarded paths, selected verification,
fresh independent Review and original c1f08532 baseline remain unchanged by
this approval operation. Concurrent Builds, stopped-Build continuation and
newer-main integration remain parked.

This records current approval and authorizes moving this exact package to
`.kogen/intents/approved/isolated-candidate-workspace/`. Approval is not proof
that the Candidate passes. This bookkeeping performs no source/test/configuration
edit, stash operation, cache mutation or Build launch; the installing run must
still start from a clean checkout and follow the approved recovery instructions.

## Historical Draft-state note before this approval

The following records the preceding reopening, not the current lifecycle state:

The 2026-09-22 request for Fable at high effort follows failed Build
`IBs1pJmboiW9BAGHIDd_ee4O`. The package is reopened in the same Draft directory
for the reviewed repair contract. That request is not approval. No current
approval applies to this revision; the previous approvals below remain history.
No Build, production edit, test repair or cache mutation is performed by this
Shaping revision. Original provenance and the existing visit entry are preserved.

## Historical approval of the source-reuse revision

The following statement describes the previously approved revision, not the
current Draft:

The human Shaper explicitly directed that the existing 38-file implementation
be preserved and reused, followed by “fix the intent then approve it”. Recorded
at 2026-09-22T09:36:37Z. This approves the narrow reviewed amendment to Intent
`01a0c467-54c1-7a5a-9cee-58d70920d780`, `isolated-candidate-workspace`:
the Developer must continue checkpoint `913ba174bffd864e0940c49d36d9e5d022333565`
as unverified source under `developer-recovery.md`, instead of discarding the
work or implementing it again from scratch.

The seven scenarios, five risks, existing guarded paths, focused-test loop,
full selected verification and fresh independent Review remain required.
`c1f08532` remains the admitted baseline; the WIP checkpoint does not replace
it. This does not resume an exhausted Build, accept historical receipts, or add
automatic continuation, concurrency or changed-main integration.

This authorizes moving the revised package back to
`.kogen/intents/approved/isolated-candidate-workspace/`. No source, test,
configuration, cache edit, stash operation or Build launch is authorized by
this approval bookkeeping. Approval is not a claim that the tests pass.

## Historical approval of the revision before source-reuse authorization

The following approval statement is preserved as historical evidence; it does
not describe the current revision's source-reuse policy:

The human Shaper explicitly approved the reviewed `isolated-candidate-workspace`
Intent, id `01a0c467-54c1-7a5a-9cee-58d70920d780`, with the current-conversation
message “approved”. Recorded at 2026-09-22T06:13:22Z. This approval covers the
basic single-Build isolation contract, its existing requirements, known repair
requirements, and focused Developer testing instructions. Concurrent Builds,
stopped-Build continuation, and newer-main integration remain parked follow-ups.

This authorizes moving this package to `.kogen/intents/approved/isolated-candidate-workspace/`.
It is not evidence that the implementation or live tests pass, does not resolve
the dirty-checkout or unsafe-cache prerequisites, and does not authorize source,
test, configuration or cache edits during this approval bookkeeping. No Build is
launched by this approval operation. Original provenance and historical evidence
remain unchanged except for explicitly labeled lifecycle notes and moved locators.

## Historical revision approval and Draft-state notes

The human Shaper explicitly approved the prior reconciled `isolated-candidate-workspace` revision with the message “Approved.” Recorded at 2026-09-21T18:40:19Z. Its Build later failed provider verification, and the package was reopened on the Shaper's direction. That approval is historical and does not authorize this amended Draft.

The amended Draft replaces the impossible strict seed-symlink rejection with contained Mix-link admission and adds scenario-mapped focused owner/setup tests for Developer iteration before Stop verification.

Historical Draft-state note, before the current approval above: the package remained in `.kogen/intents/drafts/isolated-candidate-workspace/` pending fresh explicit approval. No historical approval authorized another Build.

## Historical approvals

The human Shaper approved an earlier revision of this Intent on 2026-09-21 with the message “alright, I approve”. The subsequent Build failed, and the Shaper manually returned the package to `drafts/` for further shaping. That approval covered the seven scenarios and five risks as they then stood; it is historical evidence and did not authorize this continuation.

The earlier message “let's approve it” preceded and was superseded by a material clone-on-write amendment, so no bookkeeping was performed from that message.

The former Intent `01a0bb00-009d-7f17-9fdc-3c7ac0e86a9c` was approved on 2026-09-19 and again on 2026-09-20 against `7c7c3426`. Those approvals remain evidence of accepted historical requirements, but they do not authorize this new identity or baseline and must not be used to Build the stale package unchanged.

## Driver re-preflight at 9ff7af6e (2026-09-26)

Recorded by the driver session under the Shaper's delegation ("you don't need me
for anything, you can do everything yourself … I approve everything"; "NO STOPPING
THE BATCH … YOU FIX AND RESHAPE AND SHIT UNTIL ALL GOES WELL"). Scope is unchanged:
ROADMAP order 5, ID 7, features EXE-01, SEC-01 and BLD-12, paid targets
`live-shape-to-build` and `live-reviewer-rework`. Id, slug, title and scenario ids are
unchanged.

Baseline: main `9ff7af6e02b3f291f0196e2ec2665a1d8cb2b4b5`, where #1 (22a2db95), #2
(363c20af) and #4 `fortify-paid-verification` (9ff7af6e) have landed.
`shaping-preflight-audit` (#3) is parked and not landed, so every assumption about it
is removed: no Shaping auditor launch among the non-Build Claude launches, no
`mix kogen.audit` readiness, no `assumes_landed`. Changes:

1. `candidate-routing`: #4's controller-owned verification gets both roots
   explicitly. `Verification.run_cycle/4` runs `make -C <Candidate>`,
   `CatalogChange.check` and `TargetEvidence.capture/verify` on the Candidate, and
   keeps receipt, proof and ledger log paths relative to control. `Git.candidate_id`
   runs in the Candidate. GuardedPaths reads `.git/config` and `.git/info/exclude`
   through `git rev-parse --git-path`. `KOGEN_PROJECT_ROOT` names the Candidate.
   Every control-side locator handed to a role (`tracking_path`, review packet,
   failure receipt and log) is absolute. New selector
   `test/kogen/controller_verification_test.exs` (exists at 9ff7af6e).
2. `controller-judges-candidate`: the controller's verification children get
   `KOGEN_LIVE_LOG_DIR=<control>/.kogen/runtime/live-evidence` unless the caller set
   one, so live evidence survives `git worktree remove` (lesson 1).
3. `write-boundary-fails-closed`: `KOGEN_WRITE_BOUNDARY` joins
   `VerificationRunner.scrubbed_names/0`, so every controller-started verification
   run, including proof-selector and base-suite runs, stays unconfined.
4. INTENT.md: #4's landed design named, lesson 17 (preloaded controller, hybrid route)
   checked with no conflict, anchors re-read at 9ff7af6e.

5. Sol-high audit (8 findings, all blocking per Jev) fixed. `mix kogen.build` passes the
   control root to `Build.run`. The verification context records `candidate_root`. Role
   launches and verification children drop `MIX_BUILD_PATH`, `MIX_DEPS_PATH` and `MIX_EXS`.
   `Report.build` and citations use the Candidate root. The task context gains `control_root`.
   `KOGEN_EXPERT` carries the Candidate path (questions.md R13).

Validators and audits for this revision are in
`evidence/repreflight-2026-09-26-9ff7af6e/`.

## Driver note after Build 8Bs51yZP (2026-09-26)

Retry reuses the stashed Candidate and fixes the Reviewer's credential-binding-order finding, which is already required by scenario `candidate-creation`. No scope change.

## Historical Draft note: continuation visit before approval (2026-09-26)

A fresh Shaping conversation continued this Draft. On the Shaper's direction ("reshape against
the latest head etc.") it moved `shaped_against` from `9ff7af6e` to `98ebcfb2`, which only renames
the Jev Keychain service. It also tightened scenario `candidate-creation` to require the
credential-binding order the Reviewer of Build 8Bs51yZP enforced, backed by an ordering
assertion. It probed a rebase of the stashed Candidate onto 98ebcfb2
(evidence/reshape-2026-09-26-98ebcfb2/). Scope, id, slug, title, scenario ids and paid targets
are unchanged. At the time of this note the package was in `drafts/` awaiting approval in the
current conversation; see "Current approval (2026-09-26)".
