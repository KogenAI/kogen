# Shaping decisions

No unresolved product choice remains. The human approved this bounded Intent
with an explicit "yes" in this shaping conversation.

Provenance from this conversation:

1. The human chose **1A**: Stop owns check; outer Build runs non-check gates
   after Check settlement and again after outer rework.
2. The human chose **2B**: runtime denial before execution, not prompt-only rules.
3. After the native probe and explanation of indirect-execution limits, the
   human chose the small Build: "for now I guess the small build".

[INTENT.md](INTENT.md) owns the concrete proposed command coverage and limits.
Universal prevention of indirect execution is excluded; it is not an accepted
backlog item. The approval covers that concrete bounded contract.

If implementation reveals that the supported hook cannot deliver a required
covered behavior, return to Shaping instead of substituting post-execution
detection or silently weakening the contract.
