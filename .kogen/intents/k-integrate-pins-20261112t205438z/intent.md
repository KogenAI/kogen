# Follow the new shaping tool list in the spec

Slug: k-integrate-pins-20261112t205438z
Model: not applicable — a one-line expectation update with no state
Acceptance:
- .kogen/intents/k-integrate-pins-20261112t205438z/acceptance.feature
- features/steps/k-integrate-pins-20261112t205438z__spec.js

The pinned kogen-shaping component now offers a `check_package` tool in the shaping request. The failing scenario is spec/features/02-shaping.feature:224 A required protected edit is reported without creating an Intent or approval; its step must expect exactly the tools "read_file, view_image, list_files, search_text, probe, documentation, propose_files, check_package, submit". No pin moves, no test is skipped, no timeout is raised. After the change, gofmt -l is empty (run in cli/), and go build, go vet and go test ./... in cli/, the acceptance suite, the spec check and the packaging suite all pass.

## Decisions
- Update only the expected tool list in that scenario, following the component's new contract (source: request)

## Source comparison
- spec/features/02-shaping.feature:224 A required protected edit is reported without creating an Intent or approval: expected list lacks check_package; the component now sends it; the line is updated (source: request)
- gofmt -l, go build, go vet, go test ./... in cli/: already passing expectations, unchanged (source: request)

## Tests
- shaping request tool list includes check_package: the spec scenario at spec/features/02-shaping.feature:224 plus a scenario reading its tool line (scenario)

## Feasibility
- none
