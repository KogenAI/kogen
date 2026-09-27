# Approval

## Current approval (2026-09-27T00:36:17Z)

Approved by the Mac Studio orchestrator for the human Shaper under delegation (actor: "human Shaper, delegated to the
orchestrator"; "you gotta handle EVERYTHING", DIRECTION rule 46) against develop b2073666973da81cc5c3253ad1f524d7e6b4fccd, route codex (DIRECTION rule 51: Kogen's
Claude logins are revoked; offline-only proofs). Audit: validate.exs :ok; Sol at capacity (x2); Opus round 1 not ready
(production custody race found) → reshaped; Opus round 2: custody wording fixes applied, installer/terminal-probe parts ready.
Touches lib/kogen/process_custody.ex (lock serialisation); no D1 class. Approval is not proof that a Candidate passes.

## Addendum (2026-09-27 ~04:20)

Build j1rAH5hBP8eaumpgRT1209fC stopped on a provider capacity error during a rework turn (class provider). Reference diff evidence/candidate-j1rAH5hB-1eb24937.diff added. No contract change.

## Addendum (2026-09-27 ~05:45)

Build stopped after 2 outer resumptions on Review finding F1 (regression not deterministic; global hook). Scenario
custody-release-race now spells out the interleaving and per-lock-path seam; reference evidence/candidate-review-F1-43be3922.diff. The outcome is unchanged.
