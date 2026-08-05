# Launcher Mode × Orchestrator-Hook Bypass Matrix

Orchestrator-level hooks fire when `AGENT_TYPE` is empty (outer session). Three hooks apply; each has a different bypass profile per launcher mode. The per-role bypass uses `resolve_role()` from `_role.sh`, so a single branch covers every harness.

`pre-commit-guard.sh` is universal — it fires for all roles (not just orchestrator) — but is included here because it also gates the orchestrator level and carries an `ops` bypass.

Each mode's LOADED CONTEXT SET (what `context/*.md`/`PROJECT_CONTEXT.md` files it appends to its system prompt at launch) is a separate concern from the hook bypass profile below — declared in `config.yaml` `roles.<mode>.context_files`, see `context/harnesses.md` § Mode → Declared Context.

## Bypass Matrix

| Hook                              | `build` (default)                                                      | `debug` / `shape`                                                              | `ops`                                                                                                                      | `experiment`                                                                                | `babysit`                                                                                                                                                                                                                                                                                                                                                            |
| --------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `orchestrator-read-discipline.sh` | **gated** — path allowlist + Bash exploration-verb deny                | **bypassed** — investigation and shaping sessions need full Read + Bash access | **bypassed** — ops runs on live boxes; full inspection needed                                                              | **bypassed** — experiment sessions need full Read + Bash access for exploration             | **bypassed** — drain supervisor needs full Read + Bash access to inspect HEAD/cycle/shaping state                                                                                                                                                                                                                                                                    |
| `orchestrator-no-source-edit.sh`  | **gated** — blocks Write/Edit/MultiEdit on source files                | **scoped to `codegen/pitches/`** — shape can edit pitch drafts only            | **bypassed** — ops edits infra/ configs on live boxes                                                                      | **bypassed** — source-writable; confinement is the native `--worktree` the launcher runs in | **bypassed** — ops-equivalent posture; babysit dispatches `claude-shape`, which writes pitches                                                                                                                                                                                                                                                                       |
| `orchestrator-no-ci.sh`           | **gated** — blocks make ci/llm/mix test                                | **gated (intended)** — debug/shape do not run gate commands                    | **bypassed** — ops needs make ci / mix test for live-box inspection                                                        | **bypassed** — experiment needs gate-command access for inspection                          | **bypassed** — babysit dispatches `codegen-build --queue`, which internally runs gates                                                                                                                                                                                                                                                                               |
| `pre-commit-guard.sh`             | **gated** — blocks state-modifying git ops for all non-committer roles | **gated** — debug/shape must not write git history                             | **scoped to destructive git only** — requires the two-signal `CODEGEN_OPS_GIT_UNLOCK=1` gate; role alone no longer unlocks | **gated** — no bypass; experiment does not write git history                                | **narrow, separate exemption — NO unlock var** — exactly the tree-restoring verbs (`checkout`/`restore`/`reset --hard\|--merge\|--keep`) are allowed unconditionally; every other destructive verb (including `clean`, `commit`, `switch`) is still denied same as any non-committer role; plain `git push` after a verified ship is allowed, force-push still gated |

## How Bypasses Work

Each bypass is implemented as a `resolve_role()` branch **before** the `AGENT_TYPE` gate:

```bash
source "$(dirname "$0")/_role.sh"
_role=$(resolve_role)
[ "$_role" = "ops" ] && exit 0     # bypasses entire hook
# … or …
if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "ops" ]; then
    exit 0
fi
```

Placement before `AGENT_TYPE` gate is critical: ops outer sessions have empty `AGENT_TYPE` (indistinguishable from build orchestrator by type alone). `resolve_role()` is the only way to distinguish them.

## Canonical Pattern

`orchestrator-no-source-edit.sh` is the reference implementation — source `_role.sh` after `harnesses/claude/hooks/lib/hooks-lib.sh`, call `resolve_role()` immediately after `parse_input`, add the bypass guard before all other logic.

## Compiler-Emittable CLAUDE_ROLE_FAMILY Bypass

The `bypass_roles` field in `shared/enforcement/registry.yaml` activates compiler-generated bypass preludes for entries where the body is fully declarable (COMMAND+deny, COMMAND+allowlist, match_all). When set, the compiler:

- **Bash**: emits `source "$(dirname "$0")/_role.sh"` after `hooks-lib.sh`, then `_role=$(resolve_role); for _m in <roles>; do [ "$_role" = "$_m" ] && exit 0; done` immediately after `parse_input`, before the AGENT_TYPE gate.

The three canonical orchestrator-bypass guards (`orchestrator-read-discipline`, `orchestrator-no-ci`, `orchestrator-no-source-edit`) retain hand-authored bypass preludes: their bodies contain path allowlists and multi-branch logic that is not declarable via registry axes. The `bypass_roles` axis is proven via compiler tests with throwaway fixture registries; production use requires a fully-declarable body.

## PreToolUse/Agent Hooks

Hooks registered on the `Agent` matcher fire on every subagent spawn. These are distinct from the orchestrator-level hooks in the bypass matrix above, which fire on Bash/Read/Write tools at the outer session level.

| Hook                          | Fires when      | Action                                                             | Fail-open?           |
| ----------------------------- | --------------- | ------------------------------------------------------------------ | -------------------- |
| `operator-subagent-allowlist` | Any Agent spawn | Deny built-ins; gate Explore to debug/shape/ops/experiment/babysit | No (deny empty type) |

**Builds are driven unconditionally by the deterministic Elixir orchestration loop** (`mix codegen.loop`), not a self-orchestrating main-agent session — the loop invokes each role as a separate `codegen-call`, so no `Agent`-matcher spawn hook fires for role sequencing in the build path. The loop enforces role sequencing (`OrchestrationLoop.run/1`), cycle-state advancement (`advance_cycle_state_step/3`), and pitch-shipped autoship deterministically in Elixir instead of via Stop/SubagentStop hooks. `operator-subagent-allowlist` remains live because it fires on every `Agent`-tool spawn regardless of mode, including debug/shape/ops/experiment/babysit sessions.

## Recurring-Poll Capability: `/loop` vs Claude Scheduler Tools

Cross-harness comparison for recurring-poll and self-firing monitor stories:

**Note on test coverage**: Hook tests (bash `*_test.sh`) should mirror role-case coverage. Example: a bash hook with role-based bypass tested via `CLAUDE_ROLE=shape bash "$HOOK"` should have additional cases for `CLAUDE_ROLE` primary-role values (debug, ops) and unknown-role fail-closed behavior.

## Lessons Learned

- **[local] Hand-authored bypass guards require role additions in 4 places — plus 2-3 more when the mode also needs gate/CI and build-mode-classifier parity** — A new investigative role (e.g., experiment, babysit) must be added to: Claude `orchestrator-read-discipline.sh` (the main role-list gate), Claude `operator-subagent-allowlist.sh` (Agent-matcher allowlist` (TS Agent-matcher allowlist). All 4 must be kept in sync; missing even one blocks the role's granted tools. A mode that also dispatches gate commands or the build engine itself (babysit dispatches `codegen-build --queue`) additionally needs: `_role.sh`'s `is_build_mode()` case + its TS twin `_role.ts`'s `INVESTIGATIVE` Set (the canonical build-cycle classifier every consumer funnels through), and `orchestrator-no-ci.sh`/`orchestrator-no-ci.ts`'s bypass case (full gate-command access). This is a recurring pattern when adding a new investigative or supervisory mode — enumerate every consumer of `resolve_role()`/`resolveRole()` before shipping, not just the 4 canonical ones.


## Trigger Keywords

new launcher mode, claude-ops, claude-babysit, babysit mode, drain supervisor, CLAUDE_ROLE bypass, resolve_role, AGENT_TYPE gate, orchestrator hook leak, which hook gates, per-role bypass, ops bypass, ops mode, per-mode hook bypass, hook discipline, build orchestrator gate, debug bypass, shape bypass, hook_registrations.py, signal field

## Update When Changing

- `harnesses/claude/hooks/orchestrator-*.sh` — any bypass added/removed/changed → update matrix rows
- New launcher mode added (e.g. a new `claude-<mode>.sh`) → add a column and decide gated vs bypassed for each hook; add `resolve_role()` branch + paired `_test.sh` case
- `harnesses/claude/hooks/_role.sh` `resolve_role()` branches change (new role value) → verify matrix rows
- New `Agent`-matcher hook added → add row to PreToolUse/Agent Hooks table
- `context/launcher-hook-matrix.md` (self) — when matrix content changes
