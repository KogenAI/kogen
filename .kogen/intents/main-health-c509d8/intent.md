# Align the provider help page with the CLI login

Slug: main-health-c509d8
Model: not applicable — the change is a fixed help text with no state
Acceptance:
- .kogen/intents/main-health-c509d8/acceptance.feature
- features/steps/main-health-c509d8__steps.js

The usage errors `kogen provider login grok` and `kogen provider login openai-compatible --base-url https://a.example/v1` print the message, a blank line and the provider help page. The CLI prints a first command line `login` ("On an interactive terminal, ask which account to use and guide the sign-in"), added by the commit "Start login with the account question". Chapter 09 of the spec (`spec/prose/09-cli-and-process.md`, the page under "`kogen provider`:") and the provider page the acceptance harness compares against (`providerHelp` in `test/acceptance/support/handlers.js`) do not carry that line, so the byte-exact comparison of the rest of stdout fails in the two scenarios of `spec/features/09-cli-and-process.feature` (lines 98 and 99).

The fix is to add that one line, byte for byte as the CLI prints it, to the chapter 09 provider page and to `providerHelp` in the harness. The CLI help text is unchanged. The byte-exact comparison, the scenarios of the spec feature, the release scripts and every other file are unchanged, and no flag, setting or environment variable is added.

## Decisions
- The cause lives in this repository: the CLI provider page (cli/main.go, already carrying the login line and agreeing with cli/parse_test.go) is the intended behavior, and the chapter 09 page and the harness expected page are stale; both gain the line `  login                    On an interactive terminal, ask which account to use and guide the sign-in` as the first command line, before `  login chatgpt`. (decision: D1, round 1) (evidence: cli/main.go; cli/help.go; cli/parse_test.go; spec/prose/09-cli-and-process.md; test/acceptance/support/handlers.js) (source: request)
- The byte-exact comparison is not loosened and the CLI help is not edited: the printed page must equal chapter 09's page exactly, including the provider login line. (decision: D2, round 1) (constraint: no special case for the provider page, no skipped scenario, no edited expected text without the chapter 09 page changing) (evidence: spec/features/09-cli-and-process.feature; test/acceptance/support/handlers.js) (source: request)

## Source comparison
- Addressed: usage error at line 98 of chapter 09 (`kogen provider login grok`) prints the message, a blank line and the chapter 09 provider page byte for byte; acceptance scenario "Usage error for an unknown provider prints the chapter 09 provider page".
- Addressed: usage error at line 99 of chapter 09 (`kogen provider login openai-compatible --base-url https://a.example/v1`) likewise; acceptance scenario "Usage error for an unknown option prints the chapter 09 provider page".
- Omitted by request: release scripts, other docs, any new flag, setting or environment variable.

## Tests
- Usage error for an unknown provider prints message, blank line and the provider page exactly as chapter 09 gives it, and the page carries the login line: run the built CLI for that one usage error and compare with chapter 09 and with the harness page (integration)
- Usage error for an unknown option prints message, blank line and the provider page exactly as chapter 09 gives it: run the built CLI for that one usage error and compare with chapter 09 and with the harness page (integration)

## Feasibility
- none
