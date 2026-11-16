# Fix consumer fixtures for frozen producer

Slug: qualify-frozen-corrective-consumer
Model: not applicable — the change edits static test fixtures and has no meaningful runtime state
Acceptance:
- .kogen/intents/qualify-frozen-corrective-consumer/acceptance.feature
- features/steps/qualify-frozen-corrective-consumer__steps.js

The aggregate Kogen consumer fixtures reject the already-landed producer contracts. This Intent changes only three scenarios of the consumer feature suite (plus a narrowly needed fixture helper if the third one requires it) so that they accept the producers' additive diagnostics and the passed-Shape requirement. It does not touch component pins, the vendored kogen-loop tree, `.kogen/project.yaml`, checks, protections or producer behavior, adds no AGENTS.md, and removes or skips no scenario.

1. `spec/features/01-project-setup.feature`, "Two invalid configuration replies end init without writing anything": keep exit code 4, the primary diagnostic `provider/init_invalid: the model did not return a valid configuration; nothing was written`, no `.kogen/project.yaml` and an unchanged working tree. Replace the exact `stdout is:` comparison by `stdout contains "<primary diagnostic>"` so additive explanatory context (the check-name/reason diagnostic) is tolerated.
2. `spec/features/04-building.feature`, "A missing project tool is reported after setup and before any model request": Ruff stays absent; keep exit code 3 and zero provider requests. Replace the exact `stdout is:` block by independent `stdout contains` steps for the three required lines (`environment/tool_missing: ruff is not available`; the `is-even Build {id8} stopped in startup: tool_missing; candidate: {abs:.}; evidence: {abs:.kogen/local/runs}/{id8}; index: {abs:.kogen/local/runs}/{id8}/index-at-start` line; `kogen intent inspect {id8} --project '{abs:.}'`), so additive `commands.checks[lint]` context and next-step lines are tolerated.
3. `spec/features/claude-code-full-lineup.feature`, "A Shape or Refine checkout index or HEAD mutation stops before publication": replace the manual `the Intent "is-even" from fixture "is-even" is shaped` seed of the Refine half by a real `kogen intent shape is-even -` run through an existing deterministic fake provider that succeeds (exit 0, with real passed Shape/check/readiness evidence; for example a fake claude script such as `lineup-shape-corrections`, or `shape-ready-is-even`), then install the malicious `lineup-refine-index` fake claude and refine. Keep the `candidate/head_moved` and `candidate/baseline_changed` refusals, exit code 1 for both halves, no publication, `intent.md` unchanged and zero ChatGPT requests where they were asserted. Never write receipt fields by hand. If the seeded package differs from the manual fixture, adjust the malicious fixture JSON under `test/acceptance/fixtures/claude/` only as far as needed.

The builder must run the unchanged maintained suite (the configured checks, including `cucumber` and `spec`) and report the exact commands and results.

## Decisions
- Replace the exact stdout comparisons by `stdout contains` steps, which exist in the step vocabulary and tolerate additive lines; no new step vocabulary or production change. (evidence: spec/features/STEPS.md; test/acceptance/support/handlers.js) (source: request)
- Seed the Refine half through a fake claude Shape script that succeeds, not through ChatGPT, so the scenario's zero ChatGPT request assertion stays true.  (evidence: test/acceptance/fixtures/claude/lineup-shape-corrections.json; spec/features/claude-code-full-lineup.feature) (assumption: the chosen succeeding fake script reaches a passed readiness on the current component runtime) (source: request)
- Acceptance inspects the three scenario texts and replays their stdout/exit assertions through an independent local replay against known-good (additive context) and known-bad outputs, because the real runtime on current main does not yet emit the new diagnostics. (evidence: spec/features/01-project-setup.feature; spec/features/04-building.feature) (source: request)
- No protected path is edited: only spec/features scenario text and optionally test/acceptance fixtures change. (evidence: .kogen/project.yaml) (source: request)
- Replace exact stdout comparisons in the init-invalid and tool-missing scenarios by existing `stdout contains` steps (decision: D1, round 1) (constraint: keep exit codes, primary diagnostics, stopped-startup, inspect lines and zero provider requests) (evidence: spec/features/STEPS.md; test/acceptance/support/handlers.js; spec/features/01-project-setup.feature; spec/features/04-building.feature) (assumption: The real new diagnostic text from the frozen producers was not observed; shaping only ran local replays, so the tolerance is by substring.) (source: request)
- Seed the Refine half through a successful fake claude Shape run instead of the manual is-shaped fixture (decision: D2, round 1) (constraint: no manual receipts) (constraint: retain head_moved and baseline_changed refusals) (evidence: test/acceptance/fixtures/claude/lineup-shape-corrections.json; test/acceptance/fixtures/claude/lineup-refine-index.json; spec/features/claude-code-full-lineup.feature) (assumption: Not executed end to end; the chosen succeeding fake script and the malicious refine fixture compatibility must be confirmed by the Build's full maintained suite.) (source: request)

## Source comparison
- Request item 1 (init invalid): addressed in `spec/features/01-project-setup.feature` scenario "Two invalid configuration replies end init without writing anything".
- Request item 2 (missing tool, Ruff stays absent, no install): addressed in `spec/features/04-building.feature` scenario "A missing project tool is reported after setup and before any model request".
- Request item 3 (Refine seeded through real Shape): addressed in `spec/features/claude-code-full-lineup.feature` scenario "A Shape or Refine checkout index or HEAD mutation stops before publication".
- Pin edits (cli/go.mod, cli/go.sum, cli/loop-pin.json, vendored kogen-loop), `.kogen/project.yaml`, checks, protections, producer behavior and AGENTS.md: omitted by request; the scope acceptance scenario rejects edits to them. The frozen tuple rollout/20261116/lab/frozen-corrective-inputs.json is not changed.

## Tests
- Init invalid stdout tolerates additive context but requires the primary diagnostic: the first scenario of acceptance.feature (scenario)
- Missing tool stdout tolerates additive lines but requires tool, stopped-startup, evidence, index and inspect lines: the second scenario of acceptance.feature (scenario)
- Refine fixture is seeded by a passed fake-provider Shape: the third scenario of acceptance.feature (scenario)
- No scenario removed, no skips, no protected edits: the fourth scenario of acceptance.feature (scenario)
- Existing functional coverage of the three scenarios and the whole suite: the configured cucumber and spec checks (existing)

## Feasibility
- none
