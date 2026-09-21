# Gitless cold-receipt failure

Build `hAOGGjSCl08DLSUS-OR-CAcG` exhausted Stop verification after three cycles.

- Cycle 1 failed `check`: PTY controls reported `Bad file descriptor`, and `OfflineStageResultsTest` exceeded 60 seconds.
- Cycle 2 failed `check`: `OfflineStageResultsTest` exceeded 120 seconds.
- Cycle 3 passed `check` with 334 tests and all rehearsals, then failed `cold-offline` after its compilation, 334 tests, and rehearsals passed.
- The terminal cause was `scripts/check/offline.py:receipt_bindings` invoking `git rev-parse HEAD` inside the cold fixture. `cold_offline_test.exs` intentionally copies the repository with `--exclude=.git`.

The defect is deterministic and local. It does not require provider execution. The preceding Developer nevertheless spent paid work on three reviewer-rework runs, three Shape-to-Build runs, and live compatibility because the package required generic focused offline controls but did not name a Gitless receipt-binding control as a pre-paid barrier.

The correction requires explicit outer-owned provenance for a Gitless copy, a digest covering the exact consumed copied inputs including added/untracked files, fail-closed missing-provenance behavior, and atomic preservation of stage/cleanup evidence when binding fails. Stop retains authoritative target order: `check`, `cold-offline`, then paid targets.
