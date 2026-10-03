---
title: Reconcile reports and cleans crashed runs
domains: [kernel]
size: small
---
`kogen reconcile <run-id>` recovers a crashed run, but it prints `reconcile: unchanged` even when it changed the run, and it leaves the crashed run's workspace under `.kogen/w/<run-id>`. Make it report the recovery and remove that workspace.

## Acceptance
- A1: Reconciling a crashed run prints `reconcile: crashed`.
- A2: Reconciling a crashed run removes its workspace directory `.kogen/w/<run-id>`.
- A3: Reconciling a run whose owner is alive prints `reconcile: unchanged` and keeps its workspace directory.

## Verify
- A1: test domain=kernel
- A2: test domain=kernel
- A3: test keep domain=kernel

## Notes
Remove the workspace only through `Kogen.Workspace.destroy/1`. A crashed run without a workspace directory is still recovered normally.
