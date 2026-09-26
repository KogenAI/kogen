# Questions and choices

No open questions.

## Assumed

1. Fix only the fixture helper (a local empty core.excludesFile); never edit the user global git config.
   Reason: lesson 23; the test must not depend on the machine.
   Undo: remove the three lines from git_fixture!/0.
2. The regression uses GIT_CONFIG_GLOBAL inside a Kogen.IsolatedCase test body (own child VM), so the process-global env change
   never reaches other tests.
   Reason: a deterministic control on any machine (review Sol round 1).
   Undo: delete the regression test.

## Audit

- Round 1 (Sol): not ready — missing probe evidence; proof only red on a machine with a global exclude; scope. All adopted.
