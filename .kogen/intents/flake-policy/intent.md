---
title: Fail unchanged candidates after a red done gate
domains: [build]
size: small
---
The done gate classifies flaky tests by rerunning the failed tests with the same seed and checking the base tree. A failure that remains after that policy reaches the Cycle as a real Candidate failure. Do not grant an unchanged Candidate another done-gate pass.

## Acceptance
- A1: After a done-gate failure receives a repair, an unchanged Candidate fails as `unchanged`.
- A2: Repeated red done gates still fail when the repair cap is reached.
- A3: An unchanged Candidate after a deterministic check repair still fails as `unchanged`.

## Verify
- A1: test domain=build
- A2: test domain=build
- A3: test keep domain=build
