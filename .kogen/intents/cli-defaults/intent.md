---
title: Sensible CLI defaults
domains: [kernel]
size: small
---
Make the `kogen` command friendlier: help and version work anywhere, and project commands use the current directory when `--project` is omitted.

## Acceptance
- A1: `kogen version` without `--project` exits 0 and prints a line starting with `kogen `.
- A2: `kogen --help` without `--project` exits 0 and prints only the usage text, with no error line about `--project`.
- A3: `kogen status --json` run inside a project directory without `--project` prints that project's Intent records.

## Verify
- A1: test domain=kernel
- A2: test keep domain=kernel
- A3: test domain=kernel

## Notes
Only `Kogen.Kernel.*` may read the current directory. Keep `--project` working exactly as today.
