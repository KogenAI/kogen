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

| Role                                                        | Model  | Effort |
| ----------------------------------------------------------- | ------ | ------ |
| planner-phoenix / planner-static                            | opus   | high   |
| developer-phoenix-backend / developer-phoenix-frontend      | sonnet | medium |
| developer-static (claude twin; see per-role override below) | sonnet | high   |
| reviewer-phoenix / reviewer-static                          | sonnet | medium |
| committer                                                   | haiku  | low    |
| context-curator                                             | haiku  | low    |
| build (orchestrator)                                        | sonnet | medium |
| inspector / debug / app_build                               | sonnet | medium |
| shape / experiment                                          | opus   | high   |
| ops                                                         | sonnet | high   |

`shape` and `experiment` are pinned opus/high by design — they drive architectural decisions and
complex multi-file analysis. `debug` = sonnet/medium is also intentional (diagnostic, not creative). A
cost-tuning proposal MUST NOT suggest downgrading these — out of scope, reject without further analysis.

## Per-Role Harness Override — `developer-static` Runs on Pi

`developer-static` carries a `harness: pi` key under `.harness.developer-static` in `config.yaml` —
`RoleResolver.resolve_harness/2` reads it and `OrchestrationLoop.invoke_role/4` applies it PER ROLE, so
`codegen-build --harness=claude --stack=static` still dispatches THIS role through Pi
(`openai-codex/gpt-5.6-terra`, effort high; escalate/fallback `openai-codex/gpt-5.6-sol`, effort high)
while `planner-static` / `reviewer-static` / `committer` stay on Claude. Escalation and fallback also
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

config.yaml, role model mapping, escalate_model, escalate_effort, fallback rung, switch_model_reason, cross-provider fallback, tool_map, RoleResolver, per-role effort, harness block, load-role.sh
