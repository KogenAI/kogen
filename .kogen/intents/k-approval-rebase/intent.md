# Bind Intent approval to its Git base

Slug: k-approval-rebase
Model: .kogen/intents/k-approval-rebase/model.qnt invariants=AuthorizedBase seed=7 samples=30 steps=12
Acceptance:
- .kogen/intents/k-approval-rebase/acceptance.feature
- features/steps/approval_rebase_steps.js
- features/steps/go_driver_support.js

Fix approval movement between Git bases using the existing CLI only. An approval must identify the full Git HEAD commit on which readiness was checked and approval given. Build must refuse before inference or implementation when HEAD differs, even if every protected package byte is unchanged. Branch names alone are not authority: the exact commit is the base. A legacy marker without a recorded base cannot authorize a fresh Build until ordinary explicit approval records the current base. Do not import old Build checks or reviewer proof.

An outside agent retaining an unchanged package and intact native source custody can move it onto the new main, run `kogen intent approve <slug>` to see current readiness and both old and current full base commits, and explicitly approve the printed current full hash. No new Shape, command, flag, option, automatic approval, or provider inference is required. Readiness evidence from another HEAD is not reusable. The card shows the actual scenario names and fail-now/pass-now state on the new base. Showing a card never changes approval. A subsequent exact approval records the new base, preserves diagnostic source originals and history, and permits a fresh ordinary Build with full verification and independent review. Preserve safety against HEAD/package/custody drift during checking and publication.

Package changes or merge conflicts are not an unchanged-package move. Refuse to carry that approval, explain the changed/conflicting package and direct the caller to ordinary `kogen intent refine <slug> <full-current-sha256> <correction-file>` when applicable, or `kogen intent shape <slug> <request-file>` when a new package is needed. Do not resolve Git conflicts automatically. If all scenarios already pass on the new base, refuse reapproval for this moved Intent, show that actual outcome and direct to Refine to correct the now-obsolete contract; do not silently build a no-op. This moved-base rule does not change ordinary same-base approval of pass-now scenarios. Truly missing, changed or unsafe provenance remains a refusal: name the exact custody and preservation/restore action, followed by the usable existing `kogen intent approve <slug>` command after restoration; when exact custody cannot be restored, say to stop rather than manufacture source or approval. Intact historical provenance is not corruption merely because HEAD changed. Preserve receipt-less legacy package support, except that its old baseless approval is not fresh Build authority.

Everything else about Shape, Refine, approval hash/prefix semantics, clean paths, source safety, recovery, Resume, Build verification/review/commit and CLI syntax remains unchanged. No scheduler or automatic merge/rebase is added. Update relevant specification/documentation and focused implementation regression tests without weakening existing checks.

## Decisions
- Prioritize outside agents running parallel worktrees and landing results sequentially by merge or rebase. (source: request)
- Keep the agreed existing CLI; use the card then explicit approval on the new base, not a full reshape for an unchanged safe package. (source: request)
- Refuse stale-base Build authority and provide actionable existing-command guidance for conflicts, already-passing scenarios and genuinely unsafe custody. (source: request)
- Acceptance observes the shipped binary in two real worktrees, not names of tests the builder must invent, within the 120-second per-command approval bound. (source: request)

## Source comparison
- addressed: K-APPROVAL-REBASE fix, Studio kogen/worktree-parallel-builds parked point 2, and owner priority relayed 31 Oct 2026; outcome and Decisions retain parallel worktree workflow without scheduling or new CLI.
- addressed: de2b21b laptop experiment 30 Oct 17:33–17:41Z in a tiny Go repo allowed package-only approval on a different branch/base; acceptance switch case makes a second worktree land B, switches the approved package to another branch at B, observes refusal without inference, then explicit B approval and ordinary landing.
- addressed: 029e83b Studio/MacBook S-KSOURCES 30 Oct 21:04Z reset unchanged package onto new main and approval refused exit 5 with candidate/source_provenance_changed and current.json restoration language, forcing a fresh Shape; acceptance reset case retains real native provenance and unchanged bytes across git reset onto B and requires offline card/current readiness, approval and Build. The historical release IDs and observed exit/message are reproducer history, not new mandated error codes.
- addressed: all three Need bullets map to outcome paragraphs and executable switch/reset/pass/conflict/unsafe cases. Unsafe custody still refuses rather than inventing originals; exact command after restoration must be named.
- addressed: 1 Nov constraint following no_progress Builds 043fc6db and 619ca93e, including the absent TestApprovalRebaseInstalledMove and three other named-test executions: Acceptance uses installed Kogen commands and actual files/Git/provider observations only. No Go test name is a delivery dependency.
- superseded: current package-byte-only project.Approval and Build check in cli/project/baseline.go and cli/build/build.go; require base identity in addition, with existing source safety preserved. No requested behavior deliberately omitted.

## Tests
- Approval records the exact base and stale-base Build cannot start inference or mutate HEAD/approval: installed two-worktree switch/reset journey (regression)
- Safe unchanged native package can receive fresh base readiness and explicit approval without Shape, then verify/review/land normally: installed switch/reset journey (scenario)
- Scenarios already passing on the new base refuse moved reapproval with Refine guidance: installed pass journey (scenario)
- Changed package is not carried as unchanged authority and offers existing Refine/Shape guidance: installed conflict journey (scenario)
- Truly altered native custody refuses with exact restoration and card guidance: installed unsafe journey (scenario)
- Base identity, missing legacy base and publication drift preserve existing approval/source safety: focused approval and Build tests using real temporary Git repositories, updating existing tests of changed behavior (integration)
- Existing same-base pass-now and hash-prefix behavior remain supported: existing cli/shape approval tests and full configured checks (existing)

## Feasibility
- Quint typecheck and 30-sample 12-step TypeScript exploration passed in a scratch probe (exit 0, 0.4 s). An earlier tool invocation against /tmp/nonexistent returned exit 1 because the file did not exist; it supplied no model evidence.
- The controls below qualify the protected observer with structured known-good CLI transcripts and independently damaged late predicates. They are observer controls only, not claims that product behavior is implemented or that real-use release qualification passed. Installed journeys use the repository's existing isolated local scripted provider, not an external service.
- evidence: {"id":"rebase-observer","kind":"observer","inputs":["features/steps/approval_rebase_steps.js","features/steps/go_driver_support.js"],"observers":["features/steps/approval_rebase_steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/approval_rebase_steps.js good","exit":0,"output":"accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/approval_rebase_steps.js bad","exit":1,"output":"rejected\n"}]}
