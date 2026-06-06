# Launcher Mode × Orchestrator-Hook Bypass Matrix

Orchestrator-level hooks fire when `AGENT_TYPE` is empty (outer session). Three hooks apply; each has a different bypass profile per launcher mode. The per-role bypass uses `resolve_role()` from `_role.sh` which folds `CLAUDE_ROLE > PI_ROLE` into one value — a single branch covers both harnesses.

`pre-commit-guard.sh` is universal — it fires for all roles (not just orchestrator) — but is included here because it also gates the orchestrator level and carries an `ops` bypass.

## Bypass Matrix

| Hook                              | `build` (default)                                                      | `debug` / `shape` / `refactor`                                                 | `ops`                                                                           |
| --------------------------------- | ---------------------------------------------------------------------- | ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------- |
| `orchestrator-read-discipline.sh` | **gated** — path allowlist + Bash exploration-verb deny                | **bypassed** — investigation and shaping sessions need full Read + Bash access | **bypassed** — ops runs on live boxes; full inspection needed                   |
| `orchestrator-no-source-edit.sh`  | **gated** — blocks Write/Edit/MultiEdit on source files                | **scoped to `codegen/pitches/`** — shape/refactor can edit pitch drafts only   | **bypassed** — ops edits infra/ configs on live boxes                           |
| `orchestrator-no-ci.sh`           | **gated** — blocks make ci/llm/mix test                                | **gated (intended)** — debug/shape/refactor do not run gate commands           | **bypassed** — ops needs make ci / mix test for live-box inspection             |
| `pre-commit-guard.sh`             | **gated** — blocks state-modifying git ops for all non-committer roles | **gated** — debug/shape/refactor must not write git history                    | **bypassed** — full git surface, no restriction (interactive ops on live boxes) |

## How Bypasses Work

Each bypass is implemented as a `resolve_role()` branch **before** the `AGENT_TYPE` gate:

```bash
source "$(dirname "$0")/_role.sh"
_role=$(resolve_role)
[ "$_role" = "ops" ] && exit 0     # bypasses entire hook
# … or …
if [ "$_role" = "debug" ] || [ "$_role" = "shape" ] || [ "$_role" = "refactor" ] || [ "$_role" = "ops" ]; then
    exit 0
fi
```

Placement before `AGENT_TYPE` gate is critical: ops outer sessions have empty `AGENT_TYPE` (indistinguishable from build orchestrator by type alone). `resolve_role()` is the only way to distinguish them.

## Canonical Pattern

`orchestrator-no-source-edit.sh` is the reference implementation — source `_role.sh` after `lib/hooks-lib.sh`, call `resolve_role()` immediately after `parse_input`, add the bypass guard before all other logic.

## PreToolUse/Agent Hooks

Hooks registered on the `Agent` matcher fire on every subagent spawn. These are distinct from the orchestrator-level hooks in the bypass matrix above, which fire on Bash/Read/Write tools at the outer session level.

| Hook                          | Fires when                                                         | Action                                | Fail-open?           |
| ----------------------------- | ------------------------------------------------------------------ | ------------------------------------- | -------------------- |
| `operator-subagent-allowlist` | Any Agent spawn                                                    | Deny built-ins; gate Explore to debug | No (deny empty type) |
| `curator-before-committer`    | `committer` spawn attempted after reviewer ran but curator has not | Deny committer; prompt curator first  | Yes (no log → allow) |

`curator-before-committer` does not have a per-mode bypass — it fires in all launcher modes (`role: *`). The fail-open path (no step log) handles the edge case where the orchestrator spawns committer before any log is written.

## Headless Investigative Mode

The four investigative modes (debug, shape, refactor, ops) now have a headless variant activated by `CLAUDE_NONINTERACTIVE=1`. Headless mode passes the full 7-flag build set (`--print`, `--output-format stream-json`, `--no-session-persistence`, `--disable-slash-commands`, etc.) directly to `claude`. This does **not** change the hook bypass profile — all hooks that gate or bypass for a given role continue to fire identically in headless mode. In particular, `orchestrator-no-source-edit.sh` still scopes shape/refactor writes to `codegen/pitches/`; headless mode does NOT relax this gate. Write surface is unchanged.

## Trigger Keywords

new launcher mode, claude-ops, pi-ops, CLAUDE_ROLE bypass, PI_ROLE bypass, resolve_role, AGENT_TYPE gate, orchestrator hook leak, which hook gates, per-role bypass, ops bypass, ops mode, per-mode hook bypass, hook discipline, build orchestrator gate, debug bypass, shape bypass, refactor bypass, hook_registrations.py, signal field

## Update When Changing

- `harnesses/claude/hooks/orchestrator-*.sh` — any bypass added/removed/changed → update matrix rows
- New launcher mode added (e.g. a new `claude-<mode>.sh`) → add a column and decide gated vs bypassed for each hook; add `resolve_role()` branch + paired `_test.sh` case
- `harnesses/claude/hooks/_role.sh` `resolve_role()` branches change (new role value) → verify matrix rows
- New `Agent`-matcher hook added → add row to PreToolUse/Agent Hooks table
- `context/launcher-hook-matrix.md` (self) — when matrix content changes
