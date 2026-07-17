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

| Role                                                   | Model  | Effort |
| ------------------------------------------------------ | ------ | ------ |
| planner-phoenix / planner-static                       | opus   | high   |
| developer-phoenix-backend / developer-phoenix-frontend | sonnet | medium |
| developer-static                                       | sonnet | high   |
| reviewer-phoenix / reviewer-static                     | sonnet | medium |
| committer                                              | haiku  | low    |
| context-curator                                        | haiku  | low    |
| build (orchestrator)                                   | sonnet | medium |
| inspector / debug / app_build                          | sonnet | medium |
| shape / experiment                                     | opus   | high   |
| ops                                                    | sonnet | high   |

`shape` and `experiment` are pinned opus/high by design — they drive architectural decisions and
complex multi-file analysis. `debug` = sonnet/medium is also intentional (diagnostic, not creative). A
cost-tuning proposal MUST NOT suggest downgrading these — out of scope, reject without further analysis.

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
