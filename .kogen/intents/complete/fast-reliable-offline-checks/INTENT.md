# Make the complete offline check fast and reliable

## Outcome and retained decisions

Finish the existing test-speed work in one Build with two outer resumptions.
Aim for roughly ten seconds for the complete warm `make check` on the shaping
macOS machine with installed dependencies. This is a performance guideline,
not a hard acceptance threshold or a reason to fail a correct check. Preserve all offline coverage,
formatting, forced warnings-as-errors compilation, strict Credo, Boundary's real
negative control, and provider denial. No downloads or cached test results.
An initially empty private build cache must also pass offline; cold compilation
is outside the warm timing budget.

Preserve the human's prior requirements: all test modules explicitly async,
including both live modules; isolated mutable cwd/environment; no global fixture
lock or shared writable cache; no reduced fast subset or skipped slow cases.
Keep the terminal fake independent of EOF while preserving interactive Shaping.
Keep the bounded real fake-lifecycle Stop check, failure/correction, exactly one
outer Reviewer resumption, fresh accepting Review and resulting Commit.

## Current state and remaining work

The stopped Build's implementation remains uncommitted in this checkout. Treat
it as the starting candidate to inspect and finish, not as accepted code or a
request to repeat the original conversion. Do not discard it, commit it merely
to satisfy clean-tree preconditions, or start another Build over the dirty tree.
The last recorded complete Check passed 103 offline cases, three live excluded,
in 9.62 seconds. Cold-cache acceptance has not been demonstrated. Historical
runs varied above and below ten seconds; one passing sample does not prove
reliability, but the ten-second guideline has been demonstrated. See [diagnosis](evidence/reshaping-diagnosis.md).

1. Preserve and validate the existing speed, isolation, cleanup, role and
   settlement fixes. Use focused fixed-seed regressions (273705, 631822 and
   additional fixed seeds). Keep test selection counts and negative controls.
   The [conversion inventory](async-conversion-plan.md) is historical baseline
   guidance, not an instruction to repeat already implemented work.
2. Repair the provider-backed reviewer-rework fixture's evidence ownership.
   The nested fixture Reviewer assesses the final candidate's exact file bytes
   and current passing Check. The fixture explicitly directs initial omission
   of reviewer-notes.md and its creation only on Reviewer rework, but assigns
   auditing that temporal sequence to the outer test driver. Do not require a
   fresh nested Reviewer to certify prior transcripts it cannot access or its
   own future acceptance. Do not ask the Developer to manufacture receipts.
3. Keep outer assertions for initial omission/actionable first Reviewer rework,
   exact Developer thread resume, fresh passing Stop Check, a distinct fresh
   accepting Reviewer, exactly one outer resumption, exact bytes with one LF,
   and Commit provenance. Audit actual retained streams, structured receipts
   and archived Check records in KOGEN_RAW_LOG_DIR. Missing or out-of-order
   evidence fails the outer test, even when final files are correct. Exercise
   the audit's rejection behavior with focused offline data controls before
   spending another provider-backed run. Do not change production history
   invalidation, Reviewer access, approval rules or resumption budgets to make
   this fixture pass.
4. Remove the implementation's 9.8-second failure cutoff. Report whole-command
   timing without failing otherwise-correct checks for elapsed time. The human
   clarified on 2026-09-09 that ten seconds is only a guideline. Keep cold verification with a legitimate verification owner; do not have
   the Developer bypass gate ownership. See the remaining execution note.
5. Update scripts/check/README.md and its root README link to describe the final
   accepted verification workflow, prerequisites and timing boundary accurately.
   Keep concise final receipts with editable scripts; do not claim historical
   checks verify a subsequently changed candidate.

## Verification ownership

Only existing Make targets `check` and `live` are declared by scenarios.
Developer Stop owns check; outer Build owns live. Developers and helpers may
run focused non-gate probes, not these gates or wrapper bypasses.
The live suite remains separate from the offline performance measurement and
must pass all three existing provider-backed cases. Its outer driver owns
protocol-history assertions; nested fixture Reviewers own candidate review.
A final fresh complete warm Check and declared live result must cover the
finished candidate. Cold-cache validation remains an execution obligation for a legitimate
verification owner, not permission to fabricate evidence or breach gate ownership.

## Non-goals

No provider-latency optimization, Cloudflare authentication cleanup, shell-hook
parser overhaul, new public CLI, general test-runner framework, production
Reviewer transcript API, relaxed assertions, retries-until-green, longer
resumption budget, or unrelated production refactoring. Preserve any necessary
small internal context changes already in the candidate, subject to review.

## Provenance and navigation

This is a reshaping of fast-reliable-offline-checks after its stopped Build,
using the identity minted for this conversation. The previous identity is
01a0865c-9d03-75b7-a830-d1b093daeee5. Its approval applies only to the historical
[prior package](evidence/prior-approved-package/INTENT.md), not this revision.
The human explicitly approved this revised Intent in this conversation with
“Approve the Intent” and directed that handoff concerns not block approval.

See [scenarios](scenarios.yaml), [open decisions](questions.md), and
[observed diagnosis](evidence/reshaping-diagnosis.md).
