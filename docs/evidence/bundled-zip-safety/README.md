# KOGEN-032: bundled ZIP dependency repair

## Scope and identity

The actual implementation baseline is HEAD `43c423fc3a1c27f809327fa1c0619fde62810ae1`, not preparation source `b2c9876b27a99d19a82564821879dc42e83b03c1`. [Baseline hashes](receipts/baseline.json) record the pre-change packaging and spec manifests/locks. The only production changes are an exact `adm-zip: 0.6.1` packaging override and the corresponding lock entry. Quint remains exactly 0.33.0; its upstream requirement is still ^0.5.16. This deliberately out-of-range override is locally compatibility-tested, not certified by upstream. No unrelated packages were upgraded. Spec manifests and lock are unchanged; no spec lock regeneration or spec dependency checks are needed.

The read-only preparation at `<home>/Areas/Kogen/studio-work/kogen-repairs/dependency-advisories-20261019/` was read (README, dependency graph, advisory summary, retrievals, official snapshots and tagged source). Original evidence was not modified and is not imported by the product. Refreshed exact responses are in [refresh](refresh/), with URL, SHA-256 and UTC retrieval timestamps in [retrievals.json](refresh/retrievals.json). These are evidence only, never runtime dependencies.

## Advisory readback

Each row compares historical findings with the refreshed official response, not with an inferred security status. `null` is literal missing first-patched metadata. Ranges, severity, updated timestamp and first-patched metadata are unchanged in this refresh. All eight response hashes match the historical receipts.

| Advisory / issue | Historical range; severity; updated; first patched | Refreshed range; severity; updated; first patched |
| --- | --- | --- |
| GHSA-7q85-xj36-vmfc (allocation) | < 0.6.1; high; 2026-09-18T17:18:03Z; "0.6.1" | < 0.6.1; high; 2026-09-18T17:18:03Z; "0.6.1" |
| GHSA-8238-w5pm-2374 (async DEFLATE crash) | <= 0.6.0; high; 2026-09-29T23:10:11Z; "0.6.1" | <= 0.6.0; high; 2026-09-29T23:10:11Z; "0.6.1" |
| GHSA-c6fg-446q-cg94 (async size guard) | <= 0.6.0; medium; 2026-09-29T23:10:35Z; "0.6.1" | <= 0.6.0; medium; 2026-09-29T23:10:35Z; "0.6.1" |
| GHSA-j5f4-cc29-5x44 (permission bits) | <= 0.6.0; high; 2026-09-29T18:25:04Z; "0.6.1" | <= 0.6.0; high; 2026-09-29T18:25:04Z; "0.6.1" |
| GHSA-p634-w6r4-rjp2 (duplicate names) | <= 0.6.0; medium; 2026-09-29T23:11:04Z; "0.6.1" | <= 0.6.0; medium; 2026-09-29T23:11:04Z; "0.6.1" |
| GHSA-rcw4-f5rp-g42v (zero-size cap bypass) | <= 0.6.0; high; 2026-09-29T18:25:21Z; "0.6.1" | <= 0.6.0; high; 2026-09-29T18:25:21Z; "0.6.1" |
| GHSA-vwc7-r8mq-g2x9 (destination symlinks) | >= 0.5.9, <= 0.6.0; medium; 2026-09-08T21:20:42Z; null | >= 0.5.9, <= 0.6.0; medium; 2026-09-08T21:20:42Z; null |
| GHSA-xcpc-8h2w-3j85 (original 4GB allocation) | < 0.6.0; high; 2026-07-17T21:50:10Z; "0.6.0" | < 0.6.0; high; 2026-07-17T21:50:10Z; "0.6.0" |

Six historical advisories identify 0.6.1 as first patched; GHSA-xcpc-8h2w-3j85 identifies 0.6.0. GHSA-vwc7-r8mq-g2x9 still has first_patched_version null and range >= 0.5.9, <= 0.6.0. Separately the v0.6.1 release and comparison include fix `eaa35fa73df6108a3d6ebc9b9073371740735265`; tagged utils source checks destination components using lstat and refuses symlinks. Release/source fix evidence does not rewrite advisory metadata. No alerts are dismissed, no not-affected status or all-eight closure is asserted.

## Presence, behavior and exposure

The identified Quint 0.33.0 adm-zip import is Rust evaluator asset extraction (`refresh/quint-v0.33.0-binaryManager.ts`): Windows selects ZIP and synchronous `extractAllTo(evaluatorDir, true)`; supported macOS/Linux select tar.gz. Kogen's existing checks use TypeScript. Successful normal TypeScript checks therefore do not demonstrate ZIP-branch reachability. Async decompression and duplicate-name validation advisories have different call preconditions from this identified synchronous call. Package presence is not the same as exploit exposure. Invoking bundled Quint separately, untrusted assets and preexisting extraction directories have different preconditions. No complete call-graph or security proof is claimed.

The bounded regression uses official old 0.5.18 and the actual installed replacement, a ZIP under 4096 bytes containing `link/sentinel.txt`, a preexisting destination directory symlink and an outside sentinel within the temporary fixture. With overwrite enabled old extraction overwrites the sentinel without refusing; replacement refuses and preserves it. Ordinary extraction succeeds on both. This tests one concrete regression, not every advisory. No multi-GB inputs or upstream suite recreation are used.

## Commands and receipts

- `npm install --package-lock-only --ignore-scripts --no-audit --no-fund` in packaging/quint: exit 0, [lock-update.txt](receipts/lock-update.txt). Diff changes only adm-zip version, resolved URL, integrity and engine >=14.
- [runtime.txt](receipts/runtime.txt) records actual host/toolchain identities. Runtime/default selection, signing, supported-platform promises and configured checks are unchanged.
- The approved acceptance scenarios run `sh packaging/package.sh`, extract that exact emitted archive and `sh <archive-root>/install.sh --prefix <temporary-prefix>`. They inspect recursive installed/isolated graphs (including nested node_modules), exact installed lock bytes, generated licenses/npm-packages.md and referenced actual MIT license text, and independently `npm ci --ignore-scripts --no-audit --no-fund` copied manifests without lock mutation.
- Direct installed node-path/Quint checks cover version, typecheck, tests and seed-7 TypeScript success plus genuine false invariant violation. Installed `kogen intent approve compat --by Probe` must exit 5 with a ready card and exit 1 with the named false invariant and actual violation, not parse failure.
- Acceptance command/output and attached per-command results, archive identity/hash and observations are retained in receipts. The complete configured gate is owned by Kogen. Its observed first verification pass is retained in [configured-checks.json](receipts/configured-checks.json), extracted from `.kogen/local/runs/23128af8/log.jsonl`. This document records only observed runs, not anticipated gate success.

This archive is an uncommitted development candidate, not a qualified release. No release/deployment, Windows execution, cross-platform deterministic suite or live self-hosting qualification is claimed.

## Current manifest/lock SHA-256

- `packaging/quint/package.json`: `2d62241703d21bfcd5217491eb7933ac497f91f7e0c1854e30555efea359d4aa`
- `packaging/quint/package-lock.json`: `a9edbb742201d205457bc6abd8bcd736415b0410c30673c0f53493853ce37fdb`
- `spec/package.json`: `beb979fe2d707c7c6f9043f2e6e831e095fa0449d4730dc0c1d3ba2bd4511a2f`
- `spec/package-lock.json`: `938d609f3363f6b33983c50f6d6a79357898fd3f21915a1582a420854cef9f1c`

Official replacement integrity: `sha512-Xwrja8nx9e5o2N1my4DsKCeKpdrnACyr1wtbPxBDgGzKzKyE9kRtBFA8mWldI+RVlD7CBZNWY/wQ2+ydwOR6kQ==`, matching both refreshed registry metadata and the existing spec lock. Old official 0.5.18 integrity is asserted by the regression.

## Observed focused run

On 2026-10-19, the following command exited 0 with 3 scenarios and 6 steps passed:

```sh
NODE_PATH="$PWD/test/acceptance/node_modules" node test/acceptance/node_modules/@cucumber/cucumber/bin/cucumber.js --strict --require 'features/steps/bundled_zip_safety_steps.js' --format 'message:docs/evidence/bundled-zip-safety/receipts/acceptance.ndjson' .kogen/intents/bundled-zip-safety/acceptance.feature
```

[acceptance.txt](receipts/acceptance.txt) retains the summary; [acceptance.ndjson](receipts/acceptance.ndjson) retains scenario results and JSON attachments with commands, exit codes, output and all observations. The exact tested artifact was `dist/kogen-dev+5cccb249-darwin-arm64.tar.gz`, SHA-256 `056362c504c5883983f8359358f2f21c1dae447a354bcf429a0d1f6a0945350f`. Its installed node-path resolved Node 24.21.0; installed Quint reported 0.33.0. Both installed and isolated recursive adm-zip version sets were exactly 0.6.1. Lock stability, integrity agreement, MIT inventory and actual license text checks all passed. The installed good card exited 5; the false invariant exited 1 with `intent/not_ready`, `invariant FalseClaim violated (seed 7)`, `[violation]` and `error: Invariant violated`. Old/new sentinel and ordinary extraction observations matched the specified outcomes. Temporary fixtures were cleaned by the scenario hook; command outputs remain in the durable receipt.

`mix format` exited 0 ([format.txt](receipts/format.txt), empty output). Kogen's first verification pass in run `23128af8` completed on 2026-10-19 at 15:09:20Z. [configured-checks.json](receipts/configured-checks.json) retains the exact setup, acceptance and check commands, UTC start/finish times, exit statuses and full outputs copied from that run's execution events. All exited 0: approved acceptance (3 scenarios / 6 steps), `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix test` (143 passed, including 3 properties), `(cd cli && go test -race ./...)`, and configured chapter-04 Cucumber (14 scenarios / 206 steps). The configured commands and their actual definitions are unchanged from HEAD. This receipt precedes independent-review documentation edits; it does not claim verification of later contents. Follow `.kogen/local/runs/23128af8/` verification receipts/lineage for subsequent rounds. The reviewer read back all 15 refresh hashes and official URLs, all eight historical/refreshed advisory metadata rows, baseline/current manifest hashes, unchanged spec files and the sole adm-zip lock delta without rerunning the complete gate. Adding these retained evidence files changes later development-archive source hashes; the artifact identity above refers only to the exact archive exercised by this focused run, not a future build.
