---
description: Run one full pass of babysit's standing fleet-supervision procedure now
---

Run one full pass of the standing supervision procedure now, then report the per-node verdict rows.

Carries no procedure logic of its own — the procedure lives in the babysit system prompt (`harnesses/shared/prompt-bodies/babysit.txt`) so there is exactly one copy to keep current. This command exists so the recurring `/loop` cadence, and the launcher's own initial prompt, have a single named entry point to fire.
