## Findings

- [ADVISORY] `INTENT.md` says both fixtures allow a test-supplied `KOGEN_LIVE_LOG_DIR` to win, but the proposed `VerificationCycleFixture.run_cycle/4` unconditionally clears it and exposes no override — `INTENT.md:16-18`; `scenarios.yaml:16-22`; `evidence/prototype-2026-09-26.diff:143-153` — Narrow the caller-wins claim to `WorkspaceFixture.build!/2`, or specify and test an explicit cycle override.

- [ADVISORY] The evidence proves the seven pre-existing failures on 7ed41f66, but does not show the new verification-reuse regression itself failing on the baseline or both new tests passing with the prototype — `evidence/probe-2026-09-26.md:6-24`; `scenarios.yaml:23-49` — Add focused baseline/prototype results for each regression test.

The four guarded paths are sufficient: the registry does not catalog these files, and `async: true` plus `Kogen.IsolatedCase` makes the VM-local environment mutation viable. The prototype preserves the existing caller-wins assertion and production code.

## Verdict: ready