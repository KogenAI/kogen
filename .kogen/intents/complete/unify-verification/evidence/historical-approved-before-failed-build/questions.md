# Question disposition

No unresolved product choice remains. Current approval metadata is maintained in intent.yaml; the earlier pre-handoff approval remains historical.

- The Shaper already settled unified Stop ownership and two counters: allow two failed verification cycles, stop on the third, reset only on complete pass; Review-side outer allowance does not reset.
- Handoff correction is now explicitly settled by the completed structured-developer-handoffs decision: keep the existing shared outer allowance. Preserve its installed schema enforcement and semantic validation; do not reopen or redesign them here.
- Original configuration and first-self-build choices remain as documented. The pre-unification controller is now the handoff-capable c1c9d137 version.
- Native structured output plus terminal Stop was probed with a passing control. A valid final handoff can coexist with exhausted verification, so bound gate settlement must precede handoff success/correction routing.

The contract is complete for the later Build. Full production integration and gate acceptance belong to the later Build.
