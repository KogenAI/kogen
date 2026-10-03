---
title: Recover crashed runs
domains: [kernel, state]
size: small
---
When a Build process dies before landing, its run stays marked as running and the project claim stays held, so no further Build can start. Make `kogen reconcile <run-id>` recover such a run without touching runs that are still alive.

## Acceptance
- A1: Reconciling an unfinished run whose owner process is dead marks it failed with reason `crashed` and releases its project claim.
- A2: Reconciling an unfinished run whose owner process is alive leaves the run and the claim unchanged.
- A3: Every new run records its operating-system pid as `owner_os_pid` in run.json.

## Verify
- A1: test domain=kernel
- A2: test keep domain=kernel
- A3: test domain=state

## Notes
The owner is the `owner_os_pid` field in run.json. The liveness check belongs in the Kernel, which may run processes; State only stores and reads the owner pid. A run without `owner_os_pid` counts as not alive.
