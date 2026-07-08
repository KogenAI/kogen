# Fail-Closed Posture & INCONCLUSIVE Classification

Learnings from the fail-loud-tradeoff-rulings cycle: establishing "fail-closed everywhere except explicitly-commented anti-wedge survivors" posture across hooks, guards, and scaffold phases.

## Two INCONCLUSIVE Classes (Historical — Superseded)

Historical pattern from the retired `phoenix-dev-gate.sh` SubagentStop hook (deleted — gate execution for non-interactive builds is now owned by the Elixir loop's `LoopGate`, `test_harness/lib/codegen_test_harness/loop_gate.ex`). `static-site-build-check.sh` still distinguishes the same two INCONCLUSIVE classes on its own scope:

1. **Class 1: checker unavailable** (hook-emitted, environment fault) — `render-checker-missing`, `render-check-cmd-missing`, `render-check-cmd-failed`, `wiring-checker-missing`, `wiring-check-cmd-failed`. `BLOCK:*)` case arms placed BEFORE the `INCONCLUSIVE:*)` arms.

2. **Class 2: runtime render verdict** (emitted by render-check.js itself, browser state) — `chromium-launch-failed`, `server-unready`, `timeout`, `config-error`. Same token vocabulary, different gate, different posture — reviewing fail-closed sweeps requires checking each gate's own scope, not assuming symmetry across hooks.

## Anti-Wedge Fail-Open Survivor

Intentional, commented, justified (fail-loud-rule exemption):

**subagent-read-discipline.sh transcript-lag path** — Early-session Read may fire before step log exists (transcript lag / async flush). Denying would wedge legitimate orientation reads. Marked: `# ANTI-WEDGE FAIL-OPEN (fail-loud-rule exemption)`.

This is not a contradiction of the fail-closed ruling — it is a deliberate, narrow carve-out with an explicit justification comment. Future fail-closed sweeps must preserve it. (The `stop-cycle-guard.sh` retry-cap release, a second former survivor, was retired along with the legacy self-orchestrating harness engine it guarded.)

## Two-Signal pre-commit-guard Pattern

Destructive git bypass requires BOTH signals present:

- `CLAUDE_ROLE=ops` (or `PI_ROLE=ops`)
- **AND** `CODEGEN_OPS_GIT_UNLOCK=1` (harness-only toggle)

Neither alone unlocks commit/reset/push. Both together unlock. Documented in hook header comment. New env var is harness-internal, NOT added to `.env.sample` per operator-toggle convention (controls harness, not app runtime).

## Test Comment Drift Detection

Test comments can silently drift from actual code paths as resolution mechanisms change. Example (historical, from the retired `phoenix-dev-gate_test.sh`): a test comment claimed "CODEGEN_DIR unset" → checker-missing path, but `_self_dir` resolved via `BASH_SOURCE[0]` regardless of `CODEGEN_DIR` — on boxes with node present, the test actually exercised runtime server-unready (class-2, out of scope).

Catch: Discovered via red-green: assertion flip produced a red for a DIFFERENT reason than expected, signaling stale comment. When reviewing tests, verify comments against actual code paths, not test names alone. If a comment claims a specific code path and an assertion flip produces an unexpected error, STOP and re-diagnose the test's real behavior.

## Confinement Guard Empty-Path Scoping

`build-worker-cwd-guard.sh` `is_allowed_path()` has an internal empty-token path (`[ -z "$p" ] && return 0`) distinct from file-bearing tool empty-FILE_PATH denial:

- **Internal loop path** (`is_allowed_path()` abs-path-token iteration in `build-worker-cwd-guard.sh`): empty token = legitimate skip of non-path match. Tolerated, documented.
- **File-tool level** (inside Read/Write/Edit/MultiEdit case): Empty FILE_PATH on a file-bearing tool = anomaly → deny. Both needed distinguishing comments.

## Trigger Keywords

INCONCLUSIVE classification, two-signal pre-commit-guard, anti-wedge fail-open survivor, test comment drift, confinement guard scope, fail-loud exemptions, static-site-build-check
