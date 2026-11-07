# Show command-specific CLI help

Slug: k-cli-command-help-names-its-own-usage
Model: not applicable — help is a stateless, read-only rendering of command documentation
Acceptance:
- .kogen/intents/k-cli-command-help-names-its-own-usage/acceptance.feature
- features/steps/k-cli-command-help-names-its-own-usage__cli.js

Every public command and subcommand must answer --help and -h with its own usage, starting with its own Usage: kogen command-path line, followed by a one-line purpose, arguments, options, prerequisites, changes, exit codes and usual next command. Say explicitly when arguments, prerequisites or changes are absent. Describe actual command behavior, not hypothetical capabilities. Help exits 0 without side effects, files written, network or model calls, including outside Git. Replace global or group help at leaf commands, not the underlying commands' execution behavior. init help must describe a clean committed tree, Git identity, login and writing and committing both .kogen/project.yaml and .kogen/models.yaml. Build help must say it commits. Keep the global command list for kogen help and unknown commands. Unknown flags must still refuse, not be hidden by a help flag, including flags after help. Do not change command execution semantics or add options.

## Decisions
- Cover init, uninstall, version, context, completion and completion zsh, intent and all its public leaves, provider and its public leaves; provider names remain login arguments, not new commands. The hidden executor hook and __complete protocol are not public commands. (evidence: cli/main.go; cli/facts.go; cli/usage.go) (source: request)
- Extend the existing Usage: and Options: help layout with Purpose:, Arguments:, Prerequisites:, Changes:, Exit codes:, and Next: labels for the requested information. Carry the supported arguments/options and defaults from the current parsers, including usage filters. (evidence: cli/main.go; cli/facts.go; cli/usage.go) (source: request)
- Keep no-argument group listings, root help, unknown-command exit 2 and the -- option terminator behavior; update existing assertions that explicitly expect obsolete global/group leaf help. Implement help in unprotected CLI files without dependency changes. (evidence: cli/main.go; cli/facts.go; cli/parse_test.go; .kogen/project.yaml) (source: request)

## Source comparison
- Addressed: request Need and synthetic acceptance through command-specific help scenarios for both flags at every public path, plus the explicit seven reproductions. No behavior is deliberately omitted.
- Addressed: request init prerequisite and file literals and Build commit disclosure through focused content scenarios and the complete prose contract above.
- Addressed: request global list preservation and unknown flags through global and refusal scenarios; unknown commands retain the current usage-error status rather than being made successful. (evidence: cli/main.go)
- Conflicting historical observation: request Problem describes context returning the global list, while the current source returns a short context usage. The contract still replaces that incomplete help with the requested complete help; no reproduction is dropped. (evidence: cli/facts.go)
- Addressed: no side effects, network or model calls by static help output and isolated CLI scenarios; implementation regressions must establish that help bypasses command execution. Existing normal execution stays unchanged.

## Tests
- Own usage at every public command for both flags: run the compiled CLI outside Git and check first line and all help sections (scenario)
- Init prerequisites/files and Build commit disclosure: assert required help terms at the CLI boundary (regression)
- Help is read-only and independent of login/repository/runtime: run with isolated empty home, checkout and PATH and compare complete sandbox contents (scenario)
- Global help and unknown commands keep the global list: compare command-list payload and exit statuses (regression)
- Unknown flags still refuse even combined with help: exercise both orders and every public path (scenario)
- Help never reaches network or model execution and preserves option termination: add focused CLI dispatch regressions using the existing run/parse testing interfaces (integration)

## Feasibility
- none
