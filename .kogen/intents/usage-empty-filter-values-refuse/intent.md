# Refuse empty usage filter values

Slug: usage-empty-filter-values-refuse
Model: not applicable — this is argument validation with no new state or transitions.
Acceptance:
- .kogen/intents/usage-empty-filter-values-refuse/acceptance.feature
- features/steps/usage-empty-filter-values-refuse__steps.js

`kogen intent usage` must refuse an explicitly empty record-filter value and name the offending option instead of returning a successful report. Limit implementation changes to `cli/usage.go` and `cli/usage_test.go`. Valid filter matching, date parsing and grouping are out of scope.

## Decisions
- Refuse a zero-length value for every existing exact record-filter option (`--slug`, `--phase`, `--role`, `--model`, `--effective-model`, `--effort`, `--effective-effort`, `--outcome`, `--pass`, `--repair`) in both `--option=value` and `--option value` forms, before project discovery or report generation. Do not treat omitted options, missing arguments or nonempty strings as explicitly empty values. (evidence: cli/usage.go; spec/reference/usage.md) (source: request)
- Use the existing usage argument-error contract in both output modes: exit 2 and one JSON object on stdout with `schema_version: 1`, `kind: "usage"`, null `checkout` and `data`, and an `error` with `class: "intent"`, `reason: "invalid_argument"`, empty `paths` and `detail` in the form `kogen intent usage: --<option> must not be empty`. (evidence: cli/facts.go; cli/main.go; spec/reference/usage.md) (source: request)
- Preserve exact, case-sensitive matching of nonempty values without trimming or normalization. Keep date validation, grouping and non-filter options unchanged, including the separate missing-value diagnostic. (evidence: cli/usage.go; cli/usage_test.go; spec/reference/usage.md) (source: request)

## Source comparison
- **Addressed:** Request `ev-0824f4fc` and acceptance 1–2 replace the silent success observed after an empty string reaches the exact-match filter map (`cli/usage.go`). Decisions define the refusal and argument-error contract; the first two scenarios exercise the supplied argv forms through the built CLI. Correct and wrong overlays distinguish the fix from no validation and equals-only validation.
- **Addressed:** Request acceptance 3 preserves nonempty exact phase selection. The final scenario first demonstrates the fixture's unfiltered rows, then checks the exact filtered list. Separate wrong overlays reject nonempty filters and broaden exact matching, respectively.
- **Addressed:** The request's two-file implementation scope and exclusions are preserved in the outcome and Decisions. Nothing requested is omitted; no protected implementation edit is required. No Q&A alters scope.

## Tests
- Reject an explicitly empty record-filter value in either argument form with the offending option named: add a focused `TestUsageRejectsEmptyRecordFilters` in `cli/usage_test.go` using the existing `checkRefusedDetails` helper against a temporary project; the first two CLI scenarios also exercise both argv forms (evidence: cli/usage_test.go; cli/facts_test.go) (regression)
- Preserve nonempty exact matching: keep `TestUsageExactFiltersDatesAndUnknowns` unchanged; the final CLI scenario proves matching rows survive and differently cased and longer phases are excluded (evidence: cli/usage_test.go) (existing)

## Feasibility
- The configured Node/Cucumber runner (observed Node v24.21.0), Git (observed 2.43.0) and module-pinned Go 1.27.2 are available (toolchain probe: exit 0, 0.0 s). The driver builds with `go build -o <scratch>/kogen .` from `cli` and uses `git init -q` on a temporary project with `.kogen/project.yaml` and a retained `result.json` and `log.jsonl` under `.kogen/local/runs/11111111`. It runs `kogen intent usage --project <fixture> --json` with the scenario's extra argv and checks the usage envelope or ordered `data.requests` phases. No installed Kogen runtime, login or provider call is needed for the tested command (evidence: cli/go.mod; cli/main.go; cli/facts.go; cli/usage_test.go; .kogen/project.yaml).
- Built-CLI fixture probe: the unchanged CLI exited 0 with an empty request list for both empty filters, and reported the intended phase list unfiltered and with the nonempty filter. The existing missing-value behavior used the usage JSON envelope and exit 2 (probe exit 0, 5.3 s).
- Focused baseline Go tests for usage arguments, exact matching and existing refusal details passed (probe exit 0, 4.1 s). The correct overlay applies to the unchanged tree and each wrong overlay applies to the correct one (patch generation and apply probe: exit 0, 0.1 s).
- The final step assertions accepted the good outcome samples (exit 0, 0.1 s) and separately rejected a silent success, an error naming the wrong option and a broadened phase result (exit 1, 0.1 s).
- evidence: {"id":"usage-filter-observer","kind":"observer","inputs":[],"observers":["features/steps/usage-empty-filter-values-refuse__steps.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/usage-empty-filter-values-refuse__steps.js good","exit":0,"output":"phase error: accepted\nmodel error: accepted\nphase selection: accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/usage-empty-filter-values-refuse__steps.js bad","exit":1,"output":"phase error: rejected\nmodel error: rejected\nphase selection: rejected\n"}]}
