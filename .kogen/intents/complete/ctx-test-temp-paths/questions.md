# Questions and choices

No open questions.

## Assumed

1. The nonce combines OS pid, nanosecond time and unique_integer.
   Reason: unique_integer alone restarts per VM; pid + time make names unique across concurrent VMs and repeated runs.
   Undo: revert the helper and the call sites.

## Audit

- Shaped directly by the orchestrator (small test-only fix, lesson 26 class).
