---
title: Print status as JSON
domains: [kernel]
size: small
---
Add `kogen status --json` so scripts can read current Intent status records from standard output.

## Acceptance
- A1: `kogen status --json` prints a JSON array whose records contain `slug`, `status`, `run_id`, and `landed_sha`.

## Verify
- A1: test domain=kernel

## Notes
Unavailable `run_id` and `landed_sha` values are JSON `null`.
