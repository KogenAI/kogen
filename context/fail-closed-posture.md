# Fail-Closed Posture & INCONCLUSIVE Classification

Learnings from the fail-loud-tradeoff-rulings cycle: establishing "fail-closed everywhere except explicitly-commented anti-wedge survivors" posture across hooks, guards, and scaffold phases.

## Two INCONCLUSIVE Classes (Historical — Superseded)

Historical pattern from the retired `phoenix-dev-gate.sh` SubagentStop hook (deleted — gate execution for non-interactive builds is now owned by the Elixir loop's `LoopGate`, `test_harness/lib/codegen_test_harness/loop_gate.ex`). `static-site-build-check.sh` still distinguishes the same two INCONCLUSIVE classes on its own scope:

**Same migration, second instance — context-factcheck**: the old `context-factcheck-curator-stop.sh` (SubagentStop, dead-under-loop) was DELETED, not kept as a live-elsewhere survivor — its enforcement moved to two writer's-turn-adjacent mechanisms: `context-factcheck-edit-gate.sh` (PreToolUse, fires in ANY role's Edit/Write/MultiEdit turn on an orientation doc, scanning PROJECTED post-write content) and the in-loop curator-stage scan (`OrchestrationLoop.run_curator_doc_scan/2`, also running the cross-file index-parity scan — which can never be a per-edit gate, since an ADD needs both the file and its index row) — run BOTH before the first curator invocation (seeding a same-cycle violation into that first prompt) AND post-turn via `run_curator_doc_check/6` as the backstop for drift the curator's own edits introduce. Both share the same scan lib (`harnesses/claude/hooks/lib/context-factcheck-scan.sh`, no hook I/O). `run_curator_doc_check` is bounded by `:max_curator_doc_cycles` — a GUARANTEED FLOOR (default 1: the first rework always granted), extended past the floor only while the curator provably resolves a violation each turn (`repair_allowed?/4`), hard-capped by `@repair_progress_ceiling` (15); exhaustion fails the cycle LOUD (`{:error, ...}`) — the committer cannot Read/Edit `context/*.md` (`subagent-read-discipline.sh`), so a known-bad doc reaching it is an unfixable dead-end. Infra faults (missing script, unexpected exit code) also raise — never silently treated as clean.

1. **Class 1: checker unavailable** (hook-emitted, environment fault) — `render-checker-missing`, `render-check-cmd-missing`, `render-check-cmd-failed`, `wiring-checker-missing`, `wiring-check-cmd-failed`. `BLOCK:*)` case arms placed BEFORE the `INCONCLUSIVE:*)` arms.

2. **Class 2: runtime render verdict** (emitted by render-check.js itself, browser state) — `chromium-launch-failed`, `server-unready`, `timeout`, `config-error`. Same token vocabulary, different gate, different posture — reviewing fail-closed sweeps requires checking each gate's own scope, not assuming symmetry across hooks.

## Anti-Wedge Fail-Open Survivor

Intentional, commented, justified (fail-loud-rule exemption):

**subagent-read-discipline.sh transcript-lag path** — Early-session Read may fire before step log exists (transcript lag / async flush). Denying would wedge legitimate orientation reads. Marked: `# ANTI-WEDGE FAIL-OPEN (fail-loud-rule exemption)`.

This is not a contradiction of the fail-closed ruling — it is a deliberate, narrow carve-out with an explicit justification comment. Future fail-closed sweeps must preserve it. (The `stop-cycle-guard.sh` retry-cap release, a second former survivor, was retired along with the legacy self-orchestrating harness engine it guarded.)

## Resolved Green-on-Red: Fabricated Gate Verdict on Missing Result

`codegen-build`'s claude leg previously synthesized a fabricated `verdict: "clear"` gate-result JSON (execution_evidence 1, ALL CLEAR marker) whenever a successful dispatch left no real gate-result behind — with no gate having actually run. The sibling pi leg was correctly fail-closed (missing result → non-zero exit) the whole time; only claude carried the fabrication. Resolved: both harnesses now fail closed identically — a successful dispatch with no gate-result.json is treated as a build defect, never papered over with an invented clear verdict. The loop is the sole build engine and always gates, so this path should never fire on a healthy build; if it does, it must be loud.

**Evidence destroyed after a real gate produced it, not just fabricated when absent (resolved, historical).** `LoopGate.run_gate/2` correctly writes `gate-result.json` at gate time — but `codegen-build`'s pi leg used to unconditionally `rm -f` `codegen/gate-pending/{gate-result.json,cycle-state.json}` under the resolved `--cwd` before dispatch, and a test that invoked the real pi-leg `codegen-build` with no `--cwd` (defaulting `CWD=$PWD`) `rm -f`'d the LIVE repo's own evidence out from under an in-flight cycle. `make test`'s isolation backstop only watched `cycle-state.json` by name; a file that is already absent before AND after a run silences a presence-only check, so `gate-result.json`'s removal went undetected while the suite reported green. The committer, following its own mandatory-verdict-read rule, correctly refused to commit with no evidence to read — but nothing had made that refusal impossible to route around, since no hook read the verdict before allowing `git commit`. Fixed on three fronts: (1) the isolation backstop now snapshots and diffs EVERY file under the live `codegen/gate-pending/`, not just one by name, so any future leak of this shape fails the suite loud instead of silently; (2) a committer-scoped `committer-gate-verdict-clear` hook makes the mandatory verdict read structural — `git commit` is denied outright when `gate-result.json` is absent or its `.verdict` field is not `"clear"`; (3) the eager pre-dispatch deletion is REMOVED entirely — checkpoint evidence now survives so an interrupted cycle can resume it (see `context/loop.md` § Interrupted-Cycle Recovery). Success authority moved to a fresh, invocation-scoped `build-result.json` (matching `CODEGEN_BUILD_INVOCATION_ID`, current HEAD, `status: success`) ANDed with a clear `gate-result.json.verdict` — stale/no-op dispatch results still fail closed, but the checkpoint itself is no longer destroyed to get there.

## Two-Signal pre-commit-guard Pattern

**This gate applies to `ops` ONLY.** Destructive git bypass for `ops` requires BOTH signals present:

- `CLAUDE_ROLE=ops` (or `PI_ROLE=ops`)
- **AND** `CODEGEN_OPS_GIT_UNLOCK=1` (harness-only toggle)

Neither alone unlocks commit/reset/push. Both together unlock. Documented in hook header comment. New env var is harness-internal, NOT added to `.env.sample` per operator-toggle convention (controls harness, not app runtime).

**`babysit` has a SEPARATE, narrower posture — no unlock var, no two-signal gate.** It is allowed exactly the tree-restoring verbs (`git checkout -- <path>`, `git restore`, `git reset --hard|--merge|--keep`) needed to clear a wedge it found and verified dead, unconditionally — `CODEGEN_OPS_GIT_UNLOCK` has no effect on the babysit branch and is never required or read there. Every other destructive verb (`add`, `rm`, `mv`, `stash`, `commit`, `rebase`, `cherry-pick`, `revert`, `merge`, `switch`, `clean` without `-n`/`--dry-run`, force-push) remains denied for babysit, same as any non-committer role — history is never babysit's; committer owns it. This is a narrow, honest exemption granted because babysit's whole purpose is clearing a tree it orphaned by stopping a wedged drain, not a relaxation of the two-signal ruling — `ops`'s gate is untouched by this exemption's existence.

## Test Comment Drift Detection

Test comments can silently drift from actual code paths as resolution mechanisms change. Example (historical, from the retired `phoenix-dev-gate_test.sh`): a test comment claimed "CODEGEN_DIR unset" → checker-missing path, but `_self_dir` resolved via `BASH_SOURCE[0]` regardless of `CODEGEN_DIR` — on boxes with node present, the test actually exercised runtime server-unready (class-2, out of scope).

Catch: Discovered via red-green: assertion flip produced a red for a DIFFERENT reason than expected, signaling stale comment. When reviewing tests, verify comments against actual code paths, not test names alone. If a comment claims a specific code path and an assertion flip produces an unexpected error, STOP and re-diagnose the test's real behavior.

## Confinement Guard Empty-Path Scoping

`build-worker-cwd-guard.sh` `is_allowed_path()` has an internal empty-token path (`[ -z "$p" ] && return 0`) distinct from file-bearing tool empty-FILE_PATH denial:

- **Internal loop path** (`is_allowed_path()` abs-path-token iteration in `build-worker-cwd-guard.sh`): empty token = legitimate skip of non-path match. Tolerated, documented.
- **File-tool level** (inside Read/Write/Edit/MultiEdit case): Empty FILE_PATH on a file-bearing tool = anomaly → deny. Both needed distinguishing comments.

## All-Or-Nothing Partition — Orientation-Doc Repair Routing

`OrchestrationLoop.classify_orientation_violations/1` partitions a turn-0 orientation-doc violation set
into `:repairable` (repair via `context-curator`) or `{:not_repairable, reason}` (`InfraAbort`) — but the
partition is over the WHOLE line set, never per-line. A MIXED set (one line naming a curator-writable
doc, one naming `AGENTS.md`) is `{:not_repairable, _}` in full: the first non-writable or unparseable line
short-circuits the entire classification via `Enum.reduce_while/3`, so NO line is ever repaired while
another in the same violation payload is refused. This is deliberate fail-closed posture, not an
oversight: a partial repair would let the curator edit a doc it is entitled to while a sibling violation
(possibly the SAME structural defect, spilling across an owned and an unowned doc) goes unaddressed and
silently vanishes from the operator's view once the owned half is fixed. See `context/loop.md` § Turn-0
Sibling and pitch `orientation-preflight-routes-to-curator`.

## Trigger Keywords

INCONCLUSIVE classification, two-signal pre-commit-guard, anti-wedge fail-open survivor, test comment drift, confinement guard scope, fail-loud exemptions, static-site-build-check, classify_orientation_violations, all-or-nothing partition, mixed violation set, orientation-doc repair routing
