# Astra-medium routing review

At the Shaper's request, a fresh `gpt-6-astra` helper at medium reasoning effort
reviewed the model topology, role responsibilities, delegation evidence, and
one-Build appetite. It was asked to put quality first, then optimize latency,
root-context growth, and cost rather than endorsing the existing proposal.

## Recommendation

- Use Astra-low for the Shaping, Developer, and Reviewer roots.
- Use Luna-low for clearly specified factual discovery large enough to justify
  isolation.
- Use Terra-medium for bounded work requiring code understanding, including
  non-overlapping Developer slices with stable interfaces.
- Use Astra-medium only for a named difficult uncertainty that could materially
  change scope, architecture, correctness, or acceptance and benefits from a
  separate context or independent challenge.

The review rejected Terra-medium as the Shaping root. Shaping owns scope,
tradeoffs, and the downstream contract, and there is no repository evidence
that reducing that root preserves Intent quality. Responsiveness should instead
come from concurrent bounded investigation and asking useful human questions
before waiting.

The review also rejected an automatic Luna-to-Terra-to-Astra escalation ladder.
The root selects the appropriate profile directly. Difficult reasoning already
intertwined with root synthesis stays with the Astra-low root; the expert exists
for concentrated independent work, not to repeat the controller.

## Verification guidance

Offline tests should prove configuration propagation and prompt contracts.
Provider-backed probes should prove parent/child identities, effective model and
effort, fresh-context isolation, role-specific delegation, completed children,
root-only lifecycle outputs, and Candidate immutability. Deliberately substantial
fixtures should test discretionary delegation; ordinary Builds must not have a
spawn quota. Every live probe must assert its disposable working directory and
Git root before launch.
