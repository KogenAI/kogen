# Developer experience: isolation now, continuation later

## This installing run: continue the retained 41 files

The Shaper explicitly authorized preserving the existing implementation. The
current package retains all 41 source inputs and hashes in
`evidence/latest-implementation.json`, including repairs newer than checkpoint
`913ba174bffd864e0940c49d36d9e5d022333565`. Start the ordinary
`mix kogen.build isolated-candidate-workspace` from a clean admitted checkout;
its Developer follows `developer-recovery.md` to import or recognize that exact
saved implementation and finish it. Do not rebuild from scratch. The Shaper
need not manually time a stash pop: the Developer can restore the bound source
bytes without consuming the backup. Already restored changes are preserved.

The installing baseline controller runs in the invoking checkout. A separate
clean worktree is an optional way to leave the original dirty checkout intact,
not a requirement to use the unfinished isolation code as its own judge. The
product behavior below describes future Builds after successful installation.
The source import does not add stopped-process continuation or reset old retries.
The old controller commits on its invoking branch: a recovery-branch worktree
or separate clone does not automatically publish to this repository's main.
For that result, install on clean main here and keep unrelated work in another
checkout. No stash pop is needed: the source payloads remain in the package.

For this installation only, do not edit unrelated Drafts or other files in the
invoking checkout while the old controller is running; its ignored-file guard
still observes them. Other work may continue in a separate checkout. See
`repair-plan.md` for the concrete repair order and bootstrap limitation. This
does not require discarding the saved source or a compulsory separate worktree.

## Current scope — 2026-09-22

The Shaper narrowed this Intent to one active Build in an isolated Candidate.
Use `mix kogen.build <approved-slug>` as today. All implementation, focused tests,
verification, and Review use its Candidate; main receives only the accepted
commit when the admitted base still matches. Same-session rework inside the
running Build remains required. Failure preserves the Candidate for diagnosis;
restarting a stopped Build is not provided by this slice.

The required focused Developer feedback loop is in `developer-testing.md`.

Future existing-work detection and eligible continuation must use the same
`mix kogen.build <slug>` command. The Shaper rejected a separate resume command.
Parked, unapproved briefs now hold the separate future work:

- `.kogen/runtime/shaping-followups/intent-briefs/20-durable-build-continuation.md`
- `.kogen/runtime/shaping-followups/intent-briefs/21-concurrent-candidate-builds.md`
- `.kogen/runtime/shaping-followups/intent-briefs/22-worktree-integration.md`

## Historical proposal below — superseded, not current requirements

The following earlier proposal is retained as historical discussion, not an
implemented interface or approval. Its separate resume command was rejected;
status commands and automation alternatives were never selected. In particular,
the instruction below not to detect resumption through `mix kogen.build <slug>`
is superseded by the Shaper's explicit opposite choice above. None of these
concurrency/recovery proposals is part of the first isolation Build.

## Starting work

Run `mix kogen.build <approved-slug>` in each terminal for each independent Intent. Every invocation prints its Build id and owned worktree path. Developers implement and run the scenario's focused tests concurrently. A failure in one Build leaves its work available while the others proceed.

## Observing work

Proposed `mix kogen.build.status` lists Build id, Intent slug, state, worktree, and the concrete next action. Example states:

- `DEVELOPING`: the Developer is editing and running focused tests in its worktree.
- `WAITING_TO_FINISH`: another Build is doing its final checks before updating main. This Build's work is preserved.
- `CHECKING` / `REVIEWING`: authoritative verification or fresh independent Review is inspecting this Build's worktree.
- `NEEDS_REPAIR`: a conflict, verification failure, exhausted attempt, or unresolved Review issue prevents completion; show the actual paths/test/record and worktree.
- `COMPLETE`: main contains this Build's accepted commit.

## Finishing without using main as a scratch area

Proposed automatic-clean-update variant:

1. Only one Build at a time is allowed to perform the final current-main checks and update main. Other Developers continue working. This is a lock around finishing, not permission to merge unchecked code into main.
2. Compare the selected Build's base with current main. If they match, no update is needed. Existing valid verification and Review are reusable for the exact unchanged Candidate and inputs; otherwise perform the required checks once.
3. If main advanced, bring those changes into the selected Build's worktree. Main remains unchanged. A textual conflict pauses this Build with `NEEDS_REPAIR` and releases the finishing lock.
4. Run full required verification and fresh independent Review on the resulting worktree. A clean textual merge does not prove semantic correctness. Failures requiring further repair preserve the worktree and release the finishing lock.
5. After success, atomically advance main to the exact accepted commit, conditional on main still matching the base just checked. If main unexpectedly changed, refuse that update and retain the Candidate; never publish stale evidence.

The smallest alternative remains explicit integration: a changed base produces `NEEDS_INTEGRATION`, and the user requests step 3. Selecting either variant is still pending.

## Repairing preserved work

Proposed `mix kogen.build.resume <build-id>` uses the retained Build identity, Intent, worktree, and concrete failure to continue repair. It must not start from scratch or silently treat a fresh `mix kogen.build <slug>` as resumption. The Developer edits only within approved scope and runs focused tests in that worktree. After repair, finishing checks current main again because another Build may have published meanwhile.

Durable continuation, exact Developer/runtime availability, allowed rework budget, and newer verification-authority handling must be specified before these commands become the normative contract. Exhausted attempts are retained as history; no command silently resets them. A repair requiring changed product requirements or wider authority returns to Shaping.
