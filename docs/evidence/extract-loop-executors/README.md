# Loop extraction adoption evidence

## Source and authorship

This adoption imports the coherent externally authored v2 reference based on
`56eecd572a6e07184863939254a90d9a2dc44e96`, not a regeneration. The reference's
Opus review and Sonnet fixes are external source history, not native approval,
checkpoint, verification or delivery of this adoption. The original Kogen and
kogen-loop Apache-2.0 licence and NOTICE remain with the source.

The retained `history/integration-reference-v2.json` identifies the patch and
archive, independently SHA-256 checked before application:

- patch: `572944499c6b86d3dee6b0f3cb2b12cfa6496abe96508dff703b4331e9ad1219`
- archive: `7c9e49a61560ebdb6b2bfc1c9a4e6ab8e3333bc23c44357a88ac517e23ea84dd`

The generic source has its own prior native delivery: Build `e99deba1`, signed
commit `bbf3fdd6d2e79b96eab6af23bcd6d66212893388` in the clean canonical
`<home>/Areas/Kogen/source/kogen-loop`. This is not delivery of the
Kogen integration. Its native receipt is retained separately in `history/`.
The original bootstrap execution checkout and preserved external candidate were
not modified or resumed by this adoption.

`cli/loop-pin.json` binds the 88-file offline copy to digest
`4e1332b9f0aa686d76040466a965a43a5169ba9295631cf7bb9b8f62fb946638`.
`TestLoopPin` and Intent acceptance independently hash the actual copy. Future
copy updates use `packaging/sync-kogen-loop.sh` from qualified clean source, not
hand edits. Generic cancellation and strict task-JSON regressions stay in that
module. The parent and migration-driver Go metadata were reconciled to its
Go 1.27.2 requirement; nested-module tests must run separately.

## Historical observations, not current passes

`history/affected-acceptance.log` retains the earlier 45-scenario run with one
failure, alongside `review-diff-debug.log`. That failure used a mutating Given
as a Then, rewriting calc.py and adding a fixture commit. The v2 read-only
committed-contents assertion uses `git show HEAD:path`; the exact reviewer diff
and single-commit checks remain intact. `review-diff-fixed.log` records the
corrected historical 24-step run and `spec-after-fix.log` the historical spec
check. None is fresh final-tree verification.

The caller also reported six pre-existing Intent-driver scenario failures.
That report remains baseline evidence, not a claim of a universally green
repository suite, nor a waiver for new failures. The retained 45-scenario run is
a different observation and must not be presented as those six failures.

## Live qualification scope

`history/disposable-qualification-receipt.json` concerns only `dev+ee4666d2`.
Its approval actor correction remains explicit: the executed label was
caller-supplied attribution, not authenticated native approval. It does not
qualify this candidate. Fake Claude tests establish offline plumbing only.

Fresh implementation test logs and any isolated final-candidate live attempt
are retained under `.kogen/local/` for this Build, separately from the historical
source evidence. A real attempt must use the actual candidate archive and
private install prefix, existing subscription auth in place, exact model/effort,
normal explicit approval, Kogen verification, independent native review and one
checked commit. Authentication/resource/startup refusal is a stop or handoff,
not successful subscription qualification. No global installation, release or
remote push is part of this adoption.
