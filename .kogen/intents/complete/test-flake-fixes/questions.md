# Questions and choices

No open questions.

## Assumed

2. The custody fix is production code (lib/kogen/process_custody.ex) because the race is there (Opus round 1).
   Reason: a test-side wait cannot remove a lock the finishing run rewrote after release.
   Undo: revert process_custody.ex and the regression test.

## Audit

- Round 1 (Sol at capacity twice; Opus): not ready — process_custody cause is a production race; terminal_probe cause unproven;
  installer wording. Reshaped accordingly.
- Round 2 (Opus): custody part not ready (standin must wait for registration; serialise remove + read-modify-write, not a pid
  ownership check) → applied; installer and terminal-probe parts ready.
