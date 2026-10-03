---
title: Reconcile a crash after landing as landed
domains: [kernel]
size: small
---
A Build can crash after its commit already landed on the base branch, for example during cleanup. `kogen reconcile` then sees a dead owner and marks the run crashed, even though its commit is on the branch, so status shows a landed change as failed. Check the landing first: a run whose recorded landing commit is on the branch reconciles as landed.

## Acceptance
- A1: Reconciling a dead-owner run whose recorded landing commit is on the base branch prints `reconcile: landed` and marks the run landed.
- A2: That reconcile releases the project claim.
- A3: A dead-owner run whose recorded landing commit is not on the branch still reconciles as crashed.

## Verify
- A1: test domain=kernel
- A2: test keep domain=kernel
- A3: test keep domain=kernel

## Notes
The landing identity is the run's `landing` record (`candidate_commit`), which the State lifecycle already checks with an ancestor test for finished runs.
