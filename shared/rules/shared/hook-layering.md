# Hook Guard Layering

Universal hooks (no-cat-pipe, pre-commit) → fire every role. Role-specific (debug-bash-safety, planner-guard) → gate role boundaries only.

One hook = one concern.

❌ Mix universal + role checks
✅ Separate files, separate registrations

## SubagentStop Circuit-Breaker Composition

Two SubagentStop blockers can coexist on the same event/matcher (e.g. `developer-phoenix-backend`) without hook-ordering dependencies IF the upstream gate hook MEASURES (appends verdict, writes state, never blocks) and the downstream breaker ENFORCES (reads the measurement, blocks at threshold).

**Pattern**:

1. **Gate hook** (`phoenix-dev-gate.sh`, `static-site-build-check.sh`): Runs test suite + render check, appends `FAILED ❌` marker + writes `gate-result.json` verdict. ALWAYS completes its write, NEVER blocks on failure. Measurement only.
2. **Breaker hook** (`stop-gate-failure-breaker.sh`, `stop-spin-guard.sh`): Reads accumulated measurement state (log line count, gate-result.json verdict, transcript pattern) on every SubagentStop. Blocks when threshold exceeded. Enforcement only.

**Safety**: Breaker does NOT depend on the CURRENT stop's writes — it reads ALL prior accumulated state (e.g., `≥3 FAILED ❌` lines = at least 3 prior gate runs with repeated failure). Even if the gate's write races with breaker's read, the count from prior turns is stable and sufficient.

**Counter file naming**: When multiple blockers use the same matcher, assign distinct counter filenames to prevent clobbering:

- `stop-spin-guard.sh` → `/tmp/claude-spin-${SESSION_ID}.count`
- `stop-gate-failure-breaker.sh` → `/tmp/claude-gate-breaker-${SESSION_ID}.count`

Two concurrent SubagentStop hooks with the same counter filename will lose updates (one write overwrites the other) → cap-release fails → wedging risk. Per-blocker filenames ensure independent cap tracking.
