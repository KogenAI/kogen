# Questions and choices

No open questions.

## Assumed

1. The fix is in the stand-in, not the test: READY is the stand-in's synchronisation contract with every driver.
   Reason: the pty driver sends Ctrl-C on READY and cannot see pid files itself.
   Undo: revert the stand-in change.

## Audit

- Round 1 (Opus high): ready; note 1 (also wait for the group on the lock) applied; notes 2-4 reflected in the wording.
