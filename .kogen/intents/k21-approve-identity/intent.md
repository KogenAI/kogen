# Require a Git identity with exact fixes

Slug: k21-approve-identity
Model: not applicable — stateless pre-checks of Git configuration, no state machine
Acceptance:
- .kogen/intents/k21-approve-identity/acceptance.feature
- features/steps/k21_approve_identity_steps.js

On a fresh host or user without a Git `user.name`/`user.email`, `kogen intent approve` and `kogen intent build` stop with one clear Kogen error that names the exact fixes, instead of a generic Git failure.

Today `kogen intent approve <slug> <sha>` without `--by` already refuses when `repo.Identity()` is empty (`intent/approval_identity_unavailable`, exit 2), but its detail (`configure git user.name and user.email, or pass --by <name>`) does not give the exact commands. `kogen intent build` has no identity check at start; it fails (if at all) late, at commit time. This Intent changes both.

Approve: when `--by` is not given and Git has no usable `user.name` or `user.email` (the existing `Identity()` rule: either unset or empty), approval refuses with exit 2 and error code `approval_identity_unavailable`, with detail exactly: `no Git identity names the approver; run git config user.name "<name>" and git config user.email "<email>" (global or repository), or run kogen intent approve <slug> <sha> --by <name>` (the slug and sha placeholders are written literally as `<slug>` and `<sha>`). No approval marker is written. With `--by <name>`, or with a configured identity, behavior and output are unchanged byte for byte. No new flag, no network, no fallback identity.

Build: `checked` in `cli/build/build.go` verifies `repo.Identity()` during the start checks, after the approval/baseline/clean-tree checks and before provider login, run creation, setup or any model request. Without an identity it refuses with environment error code `git_identity_missing`, exit 3, detail exactly: `no Git identity for the commit; run git config user.name "<name>" and git config user.email "<email>" (global or repository) before building`. As for every pre-run refusal, the standard "no newly created Build run" notice follows, and no run directory, commit or provider request results. `kogen init`'s existing identity check and its message are unchanged. Resume is not changed.

## Decisions
- No Kogen fallback approver identity: approval is a human act and must name a person; a fallback such as "kogen" would put a non-person in the approval record, so Kogen refuses with the exact fix instead. (source: request)
- Both fixes use the exact commands `git config user.name "<name>"` and `git config user.email "<email>"` (global or repository) and, for approve only, `kogen intent approve <slug> <sha> --by <name>`. (source: request)
- The Build error names the two Git commands but not `--by`: `--by` only names the approver and cannot supply the commit identity, so naming it there would mislead. This is a deliberate narrowing of "the same fixes". (source: request)
- The Build check runs at Build start, not commit time. (source: request)
- Approval with a configured identity or with `--by` is unchanged. (source: request)

## Source comparison
- Approve error naming `git config user.name`, `git config user.email` and `--by`: addressed; changed detail in `cli/shape/approve.go`; scenario 1.
- `--by Someone` approves: addressed; unchanged behavior asserted; scenario 2.
- Decide fallback identity: addressed; refuse, reasoning in Decisions.
- Build stops at start with the same fixes and no model request: addressed with narrowing (no `--by` in Build text, see Decisions); new check in `checked`; scenario 3 asserts no provider request, no run, no commit.
- Byte-identical with identity or --by, no new flag, no network: addressed; existing approve tests stay and the unchanged Go tests for identity success cover it.
- All configured checks pass: addressed; existing Go tests that assert the old approve detail are updated.
- Host safety: no process stopping by name; synthetic tokens only (fake local provider).

## Tests
- Approve without `--by` and without identity names the exact fixes and writes no approval: update `cli/shape/approve_test.go` for the new detail (integration) and scenario 1 (scenario)
- Approve with `--by Someone` and no identity approves: scenario 2 (scenario)
- Approve with configured identity is unchanged: existing approve tests (existing)
- Build without identity refuses at start with the exact fixes, no run, no provider request, no commit: scenario 3 (scenario) and a Go test in `cli/build` (integration)
- Build with identity is unchanged: existing Build tests (existing)

## Feasibility
- none
