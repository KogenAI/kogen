# Run the codex route Developer at high effort

## Why

While Kogen's Claude logins are revoked, every Build runs `--route codex` (DIRECTION rule 51), whose Developer is
`gpt-6-sol` at `medium` effort. Four Builds on 2026-09-27 (durable-builds b3NQxAsT, kogen-ctx-tool XARfeVP5, failure-reports
U7f6BbQ5, kogen-ctx-index-and-search GX9zlNFh) stopped after two outer resumptions for the same main reason: the Developer
implemented most of the behaviour but wrote smoke tests instead of the exact test cases the package enumerated, and the
`high`-effort Reviewer reopened the same findings (lesson 27). The Reviewer, Expert and worker helpers already run at `high`.

## Outcome

- In `.kogen/config.yaml`, the `codex` route's `developer` is `{model: gpt-6-sol, effort: high}`. Nothing else in the file
  changes: the `codex` route's `shaping` stays `medium`; the hybrid routes (`claude-dominant-adversarial-codex`,
  `codex-dominant-adversarial-claude`), `default_route`, the `claude` route, helpers and budgets are unchanged.
- `test/kogen/configuration_support_contract_test.exs` "the tracked config resolves the codex route with the exact profiles"
  asserts `config.developer == %{model: "gpt-6-sol", effort: "high"}`; every other assertion in it is unchanged.
- `test/kogen/intent_test.exs`: the tracked-config `codex` map expects `developer: %{model: "gpt-6-sol", effort: "high"}`
  (shaping stays medium).
- `test/kogen/harness_args_test.exs` "the tracked codex route launches each root role with its exact GPT-6 profile": the
  fresh and resumed Developer args expect `model_reasoning_effort="high"` (the Reviewer already expects high); other tests in
  that file that pass literal `"medium"` arguments are unchanged.
- Tests that build routes from `test/support/route_config.ex` (e.g. native_helper_fixture_test.exs) use their own fixture
  profiles and are unchanged. No test is renamed (the ledger binds rows by test name).
- The README's copy of the config (the `codex:` route block, around the `developer:` line) shows `effort: high` for the
  codex Developer, so it matches the tracked file.

## Non-goals

- Any other route, model, budget, timeout or retry count; any code change.
