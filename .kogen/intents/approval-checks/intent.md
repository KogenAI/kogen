---
title: Check acceptance tests at approval
domains: [project, contracts, kernel]
size: small
---
Three self-builds failed late because an approved acceptance test broke a static rule (a forbidden domain reference) that only the done gate checked. The Developer may not edit the test, so each Build was lost. Let a project declare `acceptance_checks:` that `kogen approve` runs on the acceptance test before it records an approval.

## Acceptance
- A1: `kogen approve` exits non-zero, names the failing check, and records no approval when an acceptance check fails.
- A2: When every acceptance check passes, `kogen approve` records the approval and leaves no check files in the checkout.
- A3: An `{path}` argv element is replaced by `test/acceptance/<slug>_test.exs`, which holds the acceptance test while checks run.

## Verify
- A1: test domain=kernel
- A2: test domain=kernel
- A3: test domain=kernel

## Notes
`acceptance_checks` uses the same entry shape as `checks` (name, argv, timeout_ms) and defaults to an empty list. Checks run in the project checkout with the project env. Refuse to run them if `test/acceptance/<slug>_test.exs` already exists with different bytes. Kogen's own project.yaml gets `mix credo --strict {path}` and a compile check in a later change, not in this Intent.
