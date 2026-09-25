# Diagnosis summary (Shaping, 2026-09-25)

- Record sizes across the last 12 Builds: 10 KB to 9.3 MB. The largest is
  `reference_snapshots`, 4.2 MB in `DXMmwMNn…`. `kdUszVF4…` is 2.0 MB with
  embedded copies of itself.
- Per-attempt handoff 6-11 KB, notes 1.7-3.9 KB, check receipt 17-28 KB
  (mostly output), targets up to 20 KB, verification 10-58 KB.
- `kdUszVF4…` cycles, all in attempt 0: 1 failed (check), 2 failed
  (live-reviewer-rework, ExUnit timeout), 3 passed (check, live-native,
  live-reviewer-rework) on the same Candidate `b1704b4b…` as cycle 2. The final
  notes object on `role-boundary-preservation` / `codex-reviewer-rework-duration`
  (Jev 1.00), and outcome `cannot_comply`.
- Code: `lib/kogen/build.ex:403-421` (settle_outcome), `:876-915` (task and
  reviewer context), `:931-963` (snapshot_references, cited_bytes);
  `lib/kogen/build/tracking.ex:85-104` (verify_reference), `:509-515`
  (merge_reference_snapshots); `lib/kogen/codex/environment.ex:415-452`
  (config_args); `test/support/live_reviewer_rework_fixture.ex:48-59`.
