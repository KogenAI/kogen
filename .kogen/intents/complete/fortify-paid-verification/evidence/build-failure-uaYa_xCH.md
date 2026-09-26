# Build uaYa_xCHKOG1aVZSGwZywDDf failed (2026-09-26)

Candidate stashed as `fortify-paid-verification-candidate-2026-09-26` (b247b6b5a4).
- Cycle 1: check failed on 4 tests (relative paths/cwd). The Developer fixed them.
- Cycles 2-3: check and live-native passed. live-shape-to-build failed: first a native capture count
  (fixed by the Developer), then "outer driver must observe controller-owned failed-then-passed
  Verification Record history before the initial handoff".
- Root cause: two clocks. `Kogen.Build.Verification` stamped the Verification Record with the cycle's
  own `finished_at` (00:05:38.920Z), 42 ms after the check receipt's `finished_at` (00:05:38.878Z). The
  test keeps records no later than the initial attempt's last receipt, so the passing record was dropped.
- Fix: the record carries the cycle's last receipt `finished_at` (one clock). The driver proved it in a
  clone: `make check` exit 0 and `make live-shape-to-build` passed (164 s). The full tree is on branch
  `backup/fortify-paid-verification-fix4`.
