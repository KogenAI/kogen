# Approval

## Current approval

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
