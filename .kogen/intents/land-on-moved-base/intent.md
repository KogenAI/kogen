---
title: Rebase onto a moved base instead of parking
domains: [engine, workspace, docs]
size: small
---
When the base branch gains commits while a Build runs, landing parks the Build and asks for a new approval, so a queue of Intents can land only one. When the base did not move, landing still re-runs the full checks and acceptance on the identical tree. Rebase the Candidate onto the new tip and verify it there before landing, and land directly when the base did not move.

## Acceptance
- A1: When the base gains a non-conflicting commit during a Build, the Build lands with that new tip as its commit's parent.
- A2: After rebasing onto a moved base, the last checks before landing run on exactly the tree that lands.
- A3: When the base did not move, the checks and acceptance run exactly once in the Build.

## Verify
- A1: test domain=engine
- A2: test domain=engine
- A3: test domain=engine

## Notes
A rebase conflict, or red checks after the rebase, still parks the Build as today. Update the existing e2e moved-base scenario to the new behaviour. The landing compare-and-swap stays as it is. `Kogen.Workspace.Checkout` is near its 400-line limit, so put new rebase code in its own small Workspace module.
