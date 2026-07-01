# Hook Guard Layering

Universal hooks (no-cat-pipe, pre-commit) → fire every role. Role-specific (debug-bash-safety, planner-guard) → gate role boundaries only.

One hook = one concern.

❌ Mix universal + role checks
✅ Separate files, separate registrations

## Measurement vs Enforcement Composition

Two hooks can coexist on the same event/matcher without ordering dependencies IF the upstream hook MEASURES (appends verdict, writes state, never blocks) and a downstream hook ENFORCES (reads the measurement, blocks at threshold). This pattern applies to the surviving interactive-session-fallback hooks (e.g., `static-site-build-check.sh` measures; a downstream reader enforces).

**Counter file naming**: When multiple blockers use the same matcher, assign distinct counter filenames to prevent clobbering — e.g. `/tmp/claude-<hook-name>-${SESSION_ID}.count`. Two concurrent hooks with the same counter filename will lose updates (one write overwrites the other) → cap-release fails → wedging risk. Per-blocker filenames ensure independent cap tracking.

Under the Elixir orchestration loop (non-interactive builds), gate measurement AND retry-cap enforcement are both owned by the loop itself (`LoopGate.run_gate`, `OrchestrationLoop.invoke_with_retry`) rather than a pair of cooperating hooks — the loop's sequential Elixir control flow makes the measurement/enforcement split unnecessary in that path.
