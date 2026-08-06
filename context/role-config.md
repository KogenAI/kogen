# Role Config — Model/Effort/Tools + Escalation Ladder

`templates/generator/config.yaml` — the single source for per-role model, effort, tool allowlist, and
retry/fallback/escalation behavior. Three distinct blocks in the file, each read by a different
consumer:

| Block                                                     | Read by                                                                                                  |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `tools:` (per-harness tool_map, agents_dir, settings_dir) | `generate.sh`, `hook_registrations.py` at install time                                                   |
| `common:` (project_context_file, agents_file, etc.)       | template rendering (`.md.j2` variable substitution)                                                      |
| `harness:` (per-role model/effort/escalate/fallback)      | `load-role.sh` (debug/shape/ops modes) + directly via `yq` by build dispatch + `RoleResolver` at runtime |

## Role → Model/Effort (Claude harness)

Every deterministic BUILD role (developer, reviewer, committer, context-curator, app_build) runs
at canonical semantic effort `off` — an explicit operator choice, not an omission. This includes every
`escalate_effort:` and `fallback[].effort:` rung on the three developer roles: a give-up-boundary
escalation or a same-provider fallback rung still carries `off`, so a stuck build never silently
re-introduces reasoning effort on a retry. Investigative/supervisory modes (`inspector`, `debug`, `shape`,
`experiment`, `ops`, `babysit`) keep their own separately-configured higher effort, unchanged.

| Role                                                        | Model  | Effort |
| ----------------------------------------------------------- | ------ | ------ |
| developer-phoenix-backend / developer-phoenix-frontend      | sonnet | off    |
| developer-static (claude twin; see per-role override below) | sonnet | off    |
| reviewer-phoenix / reviewer-static                          | sonnet | off    |
| committer                                                   | haiku  | off    |
| context-curator                                             | haiku  | off    |
| build (orchestrator)                                        | sonnet | medium |
| inspector                                                   | sonnet | medium |
| app_build                                                   | sonnet | off    |
| debug / shape / experiment / ops                            | opus   | high   |

`shape`, `experiment`, `debug`, and `ops` are all pinned opus/high by design — they drive
architectural decisions, complex multi-file analysis, and production-server operations. A
cost-tuning proposal MUST NOT suggest downgrading these — out of scope, reject without further analysis.
`babysit` runs claude sonnet/medium — the operator-selected tier for long-running
supervised sessions, distinct from the opus/high tier used by planning/shaping/debug/ops roles.

**YAML quoting gotcha**: `effort: "off"` MUST be quoted in `config.yaml` — bare `off` is a YAML 1.1
boolean literal (parses as `false`), not the string `"off"` the loop/adapters expect. Every other
canonical effort value (`low`/`medium`/`high`/`xhigh`/`max`) is a normal scalar and needs no quoting.

## Canonical Effort Vocabulary + Build-Wide Override

Canonical effort values: `off`, `low`, `medium`, `high`, `xhigh`, `max` (`minimal` is deliberately
excluded — Claude rejects it at runtime). The single source of truth is
`harnesses/shared/effort-canonical.sh` (`CODEGEN_CANONICAL_EFFORTS` + `codegen_validate_effort`),
sourced by both `codegen-build` and `codegen-call`.

`codegen-build --effort=<e>` is a LIVE one-build override — not advisory. It threads
`CODEGEN_BUILD_EFFORT` → both harness `dispatch.sh` twins → an explicit `--effort=<e>` argv entry to
`mix codegen.loop` → `OrchestrationLoop.invoke_role/4`'s `opts[:effort_override]`. Precedence: a fixed
campaign binding (benchmark harness) still wins for its own pinned role; otherwise the override REPLACES
the resolved effort (model rung unchanged) for every other role, including an escalation/fallback rung
in progress. Omitted → each role's `config.yaml` effort (or the escalation/fallback rung's own effort)
wins unchanged.

**Per-adapter native realization** (never blind string-forwarded):

| Harness | canonical `off`                                                  | canonical `low\|medium\|high\|xhigh\|max` |
| ------- | ---------------------------------------------------------------- | ----------------------------------------- |
| claude  | no `--effort` flag (ambient `MAX_THINKING_TOKENS=0` already set) | `--effort <value>`                        |

An unrecognized effort value fails (`exit 2`) BEFORE the LLM binary starts. Telemetry
(`OrchestrationLoop.accumulate_telemetry/3`'s `dispatch:` map) records both the requested `source`
(`:role_config` \| `:build_override` \| `:escalation` \| `:campaign`) and the adapter-realized
`native_effort` string, so a cycle log always shows what was actually dispatched, not just what was
requested.

## Thinking Budget — `thinking_tokens` (Claude Launcher-Backed Modes Only)

`debug`/`shape`/`experiment`/`ops`/`babysit` each declare a positive-integer
`roles.<mode>.thinking_tokens` (currently `16000` for all five) in `config.yaml`. `load-role.sh`
validates it (fail-loud on missing/non-integer/`<=0` — no default) and exports
`ROLE_THINKING_TOKENS`; every launcher's `--settings` JSON overlay interpolates
`MAX_THINKING_TOKENS` from that var, on BOTH the interactive and headless (`CLAUDE_NONINTERACTIVE`)
branches — never a hard-coded literal. This overrides the installed global
`MAX_THINKING_TOKENS=0` (`harnesses/claude/claude-code-settings.json`), which stays `0` for
one-shot/build calls (`call-dispatch.sh`, `codegen-build`) — the ceiling is a per-mode investigation
override, not a global default. It is a CEILING, not a floor: Claude may still emit zero thinking
tokens on a simple prompt even with the overlay present. Guarded by
`harnesses/shared/mode-thinking-parity_test.sh`.

## Two Distinct Retry Mechanisms — Do Not Conflate

- **`fallback:`** — an ORDERED same-provider rung list, walked on a `switch_model` classification
  (`LoopQueue.switch_model_reason?/1`) — a role's primary model reporting "unavailable"/"disabled"/"not
  found". Tried on ANY attempt whose failure classifies as switch_model, immediately — not only at the
  end. Example: `developer-phoenix-backend` claude → `fallback: [{model: opus, effort: medium}]`.
- **`escalate_model` / `escalate_effort`** — a SINGLE give-up-boundary override, tried ONCE on the FINAL
  gate-retry attempt (see `context/loop.md` § Model Escalation Ladder for the consuming logic). Distinct
  purpose: not "this model is down", but "this model+effort combo isn't solving the problem, try
  harder before giving up."

**Both mechanisms are suppressed under a `RoleModelSweep` campaign's fixed binding** (see
`context/loop.md` § Fixed Campaign Binding and `context/test-benchmarking.md` § Role-Model-Binding
Campaigns) — a campaign arm pins one role's harness/model/effort for the whole build so a stuck
pinned role reports its arm `INCONCLUSIVE` rather than silently escalating or walking the fallback
chain to a DIFFERENT binding than the one under test. This suppression is scoped to the one
`{role, harness}` pair the active campaign names; every other role's escalation/fallback behaves
exactly as described above, unaffected.

## `escalate_model` Ladder Values (sample)

`developer-phoenix-backend` claude: primary `sonnet/medium` → escalate `opus/high` on final attempt.
`developer-static` claude: primary `sonnet/high` → escalate `opus/high`. Every dev role's escalation
rung is strictly higher-capability than its primary — never a lateral or downgrade move.

## Trigger Keywords

config.yaml, role model mapping, escalate_model, escalate_effort, fallback rung, switch_model_reason, tool_map, RoleResolver, per-role effort, harness block, load-role.sh, thinking_tokens, ROLE_THINKING_TOKENS, MAX_THINKING_TOKENS, role-model-sweep, fixed binding suppression, campaign arm
