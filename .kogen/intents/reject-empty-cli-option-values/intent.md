# Reject empty values for path options

Slug: reject-empty-cli-option-values
Model: not applicable — the change is a stateless validation rule inside one pure argument-parsing function
Acceptance:
- .kogen/intents/reject-empty-cli-option-values/acceptance.feature
- features/steps/reject-empty-cli-option-values__steps.js

This change makes the Kogen command-line parser refuse an empty value for the `--project`, `--context` and `--output` options. Today `parse` in `cli/main.go` splits a long option at the equals sign and stores the value without checking it, so `--project=` and `--context=` are accepted with an empty value, and an empty `--output` value is treated as if the option were absent. After the change each of the three options, given an empty value, makes `parse` return a usage error that names the option. Nonempty values keep populating the options in both the `--name=value` form and the `--name value` form, and `intent recover` without `--output` keeps its existing required-output usage error. Filesystem validation of nonempty paths and the option syntax are out of scope. The edits are limited to `cli/main.go` and `cli/parse_test.go`.

## Decisions
- An empty value for `--project`, `--context` or `--output` is refused by `parse` with a usage error. The error message contains the option as written with two dashes (for example `--context`) and says the value is empty; the usage error follows the existing `kogen <command path>: ...` shape, for example `kogen intent build: --context must not be empty`. (evidence: cli/main.go; cli/parse_test.go) (source: request)
- The refusal applies to both the `--name=` form and the `--name ''` separate-value form, because both hand `parse` an empty value for a path option; the request lists the equals form as the reproducing case and refuses "empty values" in general.  (evidence: cli/main.go) (assumption: the user confirms an explicitly empty separate argument such as `--project ''` is refused too) (source: request)
- Other options (`--by`, `--json`) and positionals are not changed. (evidence: cli/main.go) (source: request)
- An empty `--output` is refused with the empty-value error, not treated as absent; recover without `--output` at all keeps the existing `kogen intent recover: missing --output <directory>` error. (evidence: cli/main.go) (source: request)
- Nonempty values keep populating the invocation: `--project`, `--context` and `--output` in the equals form and the separate-value form. (evidence: cli/main.go; cli/parse_test.go) (source: request)
- The acceptance runs the real `parse` function through a Go test binary compiled with an overlay that adds a throwaway probe test file, so no file of the checkout is created and no named test has to be invented by the Build. (evidence: cli/testmain_test.go; features/steps/chat-completions-streaming-docs__steps.js) (source: request)

## Source comparison
- Request item 1 (`--project=` refused naming `--project`): addressed by the "Parsing an empty project option is refused" scenario, plus the separate-value variant.
- Request item 2 (build with `--context=` refused naming `--context`): addressed by the "Parsing an empty context option is refused" scenario.
- Request item 3 (recover with `--output=` refused naming `--output`): addressed by the "Parsing an empty output option is refused" scenario; the message must say the value is empty, which tells it from the existing missing-output error.
- Request item 4 (nonempty equals-form and separate forms keep populating): addressed by the nonempty scenarios and the existing missing-output scenario.
- Out of scope and not addressed: filesystem validation of nonempty paths, option syntax changes.

## Tests
- Empty `--project`, `--context` and `--output` values are refused with a usage error naming the option: add cases to the parse tests in `cli/parse_test.go` (unit)
- Nonempty equals-form and separate-value forms still populate project, context and output, and recover without output keeps its error: keep and extend the parse tests in `cli/parse_test.go` (unit)
- The same rules observed through the real `parse` function: `.kogen/intents/reject-empty-cli-option-values/acceptance.feature` (scenario)

## Feasibility
- none
