# Reject unsupported efforts when config is read

Slug: k22-effort-validation
Model: not applicable — pure validation of configuration text; no state machine
Acceptance:
- .kogen/intents/k22-effort-validation/acceptance.feature
- features/steps/k22_effort_validation_steps.js

When `.kogen/project.yaml` is read (`project.ParseConfig`/`LoadConfig`, used by every command), each role's `effort` is checked, so a bad value fails before setup, readiness or any provider call. This applies to `models.shape|build|review` and to `shape_workers.read|probe|draft`. No network, no new setting; configurations that load today with a supported effort load byte-identically (same `Config` values).

Known effort lists (exact, case-sensitive match):
- `provider: anthropic`: `low, medium, high, xhigh, max` (docs/configuration.md documents low/medium/high/max and says upstream also documents xhigh; xhigh stays accepted, as Kogen's tests and docs already use it).
- `provider: supergrok`: `low, medium, high, xhigh`.
- `executor: claude-code` (any role): `low, medium, high, xhigh, max`, the levels the Claude Code CLI accepts for `--effort` (existing Kogen tests already pass `xhigh`; the CLI reference page could not be retrieved in full, so keep the list as written).

No known list (pass-through, unchanged from today): ChatGPT (omitted provider or `chatgpt`), `opencode-go` and `openai-compatible`. Any nonempty effort other than `ultra` is accepted there. `ultra` is rejected on every route, since no route lists it, including these pass-through routes.

Error: the existing `environment/project_config_invalid` (exit 3) with one `line N: ...` entry per problem, N being the line of the `effort` key, in the form `line N: models.build.effort "ultra" is not supported; accepted: low, medium, high, xhigh, max`. For a pass-through route the tail is `accepted: any effort except ultra`. The prefix `<path>.effort "<value>" is not supported` and the `accepted: <comma-separated list>` text are contract.

Replaced: the statements "any nonempty effort is accepted for every provider" in README.md and docs/configuration.md (open model selection, Anthropic roles, claude-code executor) are updated to describe the lists above and the `ultra` rule. Existing Go tests that assert acceptance of an effort now rejected (for example anthropic `default` in cli/project/config_test.go, and the generated golden data under cli/project/testdata holding an anthropic `default` effort) are updated to supported efforts; the golden must stay consistent with its generator.

## Decisions
- Validation lives in config reading, not at the provider (source: request)
- Roles without a known list keep pass-through, except that ultra is rejected everywhere (source: request)
- Shape workers are roles too and are validated the same way (source: request)
- OpenCode Go is treated as having no known list, since its default/high entries are hints only (source: request)

## Source comparison
- Request 1 (check each role's effort against known route lists, error with line and accepted values): addressed for anthropic, supergrok and claude-code; scenarios 1-4.
- Request 2 (pass-through where no list is known, say so): addressed for ChatGPT, opencode-go, openai-compatible; stated above; scenario 6.
- Request 3 (ultra rejected on every route not listing it): addressed for all routes; scenarios 1, 3, 5.
- Must stay (valid configs byte-identical, no network, no new setting): addressed; scenarios 7-9; no setting added.
- Acceptance: Anthropic ultra with line number and list and no setup run: scenario 1 (sentinel SETUP_RAN absent; config fails before any setup). claude-code bad effort: scenario 2. Kogen's own config and docs examples load: scenarios 8-9. All configured checks pass: required of the Build.
- Conflicting: the pass-through rule versus rejecting ultra on pass-through routes is resolved by rejecting only ultra there.
- Host safety: tests start only their own child processes and make no provider calls.

## Tests
- anthropic ultra rejected with line and list, no setup run: acceptance scenario 1 (scenario)
- claude-code unsupported effort rejected with line and list: scenarios 2-3 (scenario)
- supergrok list, unknown-list routes, shape workers: scenarios 4-6 (scenario)
- supported efforts, own config and docs examples still load: scenarios 7-9 (scenario)
- per-route accept/reject table in the validator: add a unit test in cli/project/config_test.go and update tests asserting now-rejected efforts (unit)

## Feasibility
- `kogen intent build abc` loads the configuration before looking up the Intent and prints `environment/project_config_invalid` with `  line N: ...` and exit 3 on config problems; with a valid config it fails with intent/not_found exit 2. (probe 1: exit 0, 0.0 s)
- The Claude Code CLI reference could not be retrieved past its commands table; the claude-code list rests on existing Kogen usage and is untested uncertainty.
