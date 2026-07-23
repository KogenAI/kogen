# Role Config — Model/Effort/Tools + Escalation Ladder

`templates/generator/config.yaml` — the single source for per-role model, effort, tool allowlist, and
retry/fallback/escalation behavior. Three distinct blocks in the file, each read by a different
consumer:

| Block                                                     | Read by                                                                                                  |
| --------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `tools:` (per-harness tool_map, agents_dir, settings_dir) | `generate.sh`, `hook_registrations.py` at install time                                                   |
| `common:` (project_context_file, agents_file, etc.)       | template rendering (`.md.j2` variable substitution)                                                      |
| `harness:` (per-role model/effort/escalate/fallback)      | `load-role.sh` (debug/shape/ops modes) + directly via `yq` by build dispatch + `RoleResolver` at runtime |

## Role → Model/Effort (Claude harness; Pi mirrors with its own model IDs)

Every deterministic BUILD role (planner, developer, reviewer, committer, context-curator, app_build) runs
at canonical semantic effort `off` — an explicit operator choice, not an omission. This includes every
`escalate_effort:` and `fallback[].effort:` rung on the three developer roles: a give-up-boundary
escalation or a same-provider fallback rung still carries `off`, so a stuck build never silently
re-introduces reasoning effort on a retry. Investigative/supervisory modes (`inspector`, `debug`, `shape`,
`experiment`, `ops`, `babysit`) keep their own separately-configured higher effort, unchanged.

| Role                                                        | Model  | Effort |
| ----------------------------------------------------------- | ------ | ------ |
| planner-phoenix / planner-static                            | opus   | off    |
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
`babysit` runs claude sonnet/medium and pi terra/medium — the operator-selected tier for long-running
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
| pi      | `--thinking off`                                                 | `--thinking <value>`                      |

An unrecognized effort value fails (`exit 2`) BEFORE the LLM binary starts, on both adapters. Telemetry
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
tokens on a simple prompt even with the overlay present. Pi has no equivalent setting — Pi launchers
already pass `--thinking "$ROLE_EFFORT"` per exec site. Guarded by
`harnesses/shared/mode-thinking-parity_test.sh`.

## Anthropic → ChatGPT Tier Map (Pi Model IDs)

Every Pi role in `config.yaml` mirrors its Claude twin's tier through this repo-wide map onto the
`gpt-5.6` generation (see `pi --list-models`):

| Anthropic tier | Pi model                     | Cost ($/Mtok in/out) | Context |
| -------------- | ---------------------------- | -------------------- | ------- |
| haiku          | `openai-codex/gpt-5.6-luna`  | 1/6                  | 372K    |
| sonnet         | `openai-codex/gpt-5.6-terra` | 2.5/15               | 372K    |
| opus           | `openai-codex/gpt-5.6-sol`   | 5/30                 | 372K    |

Effort is always mirrored from the role's claude twin — never derived from the previous Pi model ID.
Every Pi `model`/`escalate_model`/`fallback[].model` value in `config.yaml` is one of these three IDs.

## Per-Role Harness Override — `developer-static` Runs on Pi

`developer-static` carries a `harness: pi` key under `.harness.developer-static` in `config.yaml` —
`RoleResolver.resolve_harness/2` reads it and `OrchestrationLoop.invoke_role/4` applies it PER ROLE, so
`codegen-build --harness=claude --stack=static` still dispatches THIS role through Pi
(`openai-codex/gpt-5.6-terra`, effort high; escalate/fallback `openai-codex/gpt-5.6-sol`, effort high —
the same tier map above, mirroring its claude twin's sonnet/high and opus/high rungs) while
`planner-static` / `reviewer-static` / `committer` stay on Claude. Escalation and fallback also
resolve on the overridden harness — a Pi role never falls back to a Claude model. Measured ~3.4x
cheaper than the Claude/sonnet twin for this role at equal call count (bench `20260717_064438`); the
Claude `pi:` block above stays as the twin config for reference/reversion (comment out `harness: pi`
to isolate a pure Claude-vs-Pi benchmark comparison). This is a per-role decision, not a policy of
migrating other roles to Pi — every other role's harness stays whatever the build was invoked with.

## Two Distinct Retry Mechanisms — Do Not Conflate

- **`fallback:`** — an ORDERED same-provider rung list, walked on a `switch_model` classification
  (`LoopQueue.switch_model_reason?/1`) — a role's primary model reporting "unavailable"/"disabled"/"not
  found". Tried on ANY attempt whose failure classifies as switch_model, immediately — not only at the
  end. Example: `developer-phoenix-backend` claude → `fallback: [{model: opus, effort: medium}]`.
- **`escalate_model` / `escalate_effort`** — a SINGLE give-up-boundary override, tried ONCE on the FINAL
  gate-retry attempt (see `context/loop.md` § Model Escalation Ladder for the consuming logic). Distinct
  purpose: not "this model is down", but "this model+effort combo isn't solving the problem, try
  harder before giving up."

Cross-provider fallback rungs (an Anthropic model on a Pi/openai-codex role or vice versa) are
explicitly OUT OF SCOPE for the current `fallback:` mechanism — tracked separately, not yet built.

**Both mechanisms are suppressed under a `RoleModelSweep` campaign's fixed binding** (see
`context/loop.md` § Fixed Campaign Binding and `context/test-benchmarking.md` § Role-Model-Binding
Campaigns) — a campaign arm pins one role's harness/model/effort for the whole build so a stuck
pinned role reports its arm `INCONCLUSIVE` rather than silently escalating or walking the fallback
chain to a DIFFERENT binding than the one under test. This suppression is scoped to the one
`{role, harness}` pair the active campaign names; every other role's escalation/fallback behaves
exactly as described above, unaffected.

## Pi Provider Selection — Inferred from Model Prefix, Never `--provider`

Pi ships ~34 providers and resolves the provider FROM the `<provider>/` prefix on `--model` — no
`--provider` flag is needed or passed by any launcher. All 7 pi launcher sites
(`call-dispatch.sh`, `pi-shape.sh` ×2, `pi-debug.sh`, `pi-ops.sh`, `pi-babysit.sh`,
`pi-experiment.sh`) pass only the already-prefixed `--model "$ROLE_MODEL"` / `--model "$MODEL"`.
Every pi model currently in `config.yaml` is `openai-codex/`-prefixed, so today's routing is
unchanged; a role bound to a different `<provider>/<model>` (once that provider is authenticated)
routes correctly with zero launcher edits. NEVER re-add a hardcoded `--provider <name>` flag — it
would defeat per-role cross-provider routing that the model prefix alone already provides.

## `escalate_model` Ladder Values (sample)

`developer-phoenix-backend` claude: primary `sonnet/medium` → escalate `opus/high` on final attempt.
`developer-static` claude: primary `sonnet/high` → escalate `opus/high`. Every dev role's escalation
rung is strictly higher-capability than its primary — never a lateral or downgrade move.

## Pi Tool Mapping (unmapped tool = hard abort at generation time)

Pi's tool registry: `bash, edit, find, grep, ls, read, write` (built-in) + `subagent,
ask_user_question, web_search, fetch_webpage` (from `harnesses/pi/pi-extensions/*`). An unmapped Claude
tool name in a role's allowlist ABORTS template generation — Pi silently ignores unknown `--tools` names
at runtime, so generation-time is the only enforcement point; never let a tool silently vanish from a
role's grant.

## Trigger Keywords

config.yaml, role model mapping, escalate_model, escalate_effort, fallback rung, switch_model_reason, cross-provider fallback, tool_map, RoleResolver, per-role effort, harness block, load-role.sh, thinking_tokens, ROLE_THINKING_TOKENS, MAX_THINKING_TOKENS, role-model-sweep, fixed binding suppression, campaign arm
