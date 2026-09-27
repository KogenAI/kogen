# Approval

## Current approval (2026-09-26T22:10:18Z)

Approved by the Mac Studio orchestrator for the human Shaper under delegation (actor: "human Shaper, delegated to the
orchestrator"), against develop 3ab70dcef925bbaa228b57fc538e745bc3318dd6, route claude-dominant-adversarial-codex.
Delegation: "shape and builds things that are in the roadmap hopefully without my involvement … drive everything without
stopping" (2026-09-26); "you gotta handle EVERYTHING" (2026-09-26, DIRECTION rule 46). Row: GOAL.md #2 (lessons 19–22).
Audit: validate.exs :ok; review rounds 1–5 (Astra, Sol, Opus) not ready → reshaped each time (evidence/reviews/);
round 6 (Opus, final) ready; its three advisories applied. No DIRECTION D1 protected class is touched.
Approval is not proof that a Candidate passes.

## Re-baseline and route addendum (2026-09-27 ~02:10, orchestrator, delegated)

Build qlJ7O9ljtPo2EuvI9httlWby stopped on a revoked Kogen Claude login (lesson 24). Re-baselined to b2073666
(isolate-test-git-config: one unguarded test file; no overlap). Builds on `--route codex` per DIRECTION rule 51 (offline-only
proofs). Reference diff evidence/candidate-qlJ7O9lj-f6ccf164.diff. No contract change.

## Addendum (2026-09-27 ~02:55, orchestrator, delegated)

Build Cz_797R_H-oABPpji8aMO5QF: scenario rework-still-runs-every-input-check corrected (the test process, not the role,
rewrites the record version — the role can't write control); reference diff evidence/candidate-Cz_797R-ee3b46d6.diff. No other contract change.

## Re-baseline (2026-09-27 ~06:12)

Re-baselined to 98f65b671786f0b87ff1a1d923ca7dff03155a0a (test-flake-fixes: process_custody.ex + three tests, no overlap). Risk
record-version-test-must-be-rewritten added. Route codex (rule 51). No contract change.

## Addendum (2026-09-27 ~06:40)

Build xitayJZ5n11XoYaFaPfofbSg stopped as unchanged_candidate (Developer judged :532 a flake). Risk record-version-test-fails-under-full-gate added. No contract change.
