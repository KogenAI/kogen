# Add a Providers guide that tracks the CLI

Slug: provider-catalog-docs
Model: not applicable — documentation and a drift test; there is no state to model
Acceptance:
- .kogen/intents/provider-catalog-docs/acceptance.feature
- features/steps/provider-catalog-docs__steps.js

Add docs/providers.md as the source of truth for provider documentation and link it from README.md and docs/configuration.md. Today `kogen provider list` shows logins and docs/configuration.md lists provider names, but no single page compares providers and QwenCloud is not named anywhere. The page compares every provider name that `kogen provider login` accepts (chatgpt, supergrok, opencode-go, anthropic, claude-code, openai-compatible) in one table with the columns Provider, Account or key needed, Roles verified, Built in or custom endpoint and Setup. A role is marked verified only when the same cell names a qualification record, a path in this repository that exists; otherwise it is marked not qualified. An openai-compatible section holds a QwenCloud subsection labelled exactly "experimental: Build verified with Claude Review; Shape and Review not qualified". Its setup is: run `kogen provider login openai-compatible`, enter the base URL on line 1 and the key on line 2, then add `build: {provider: openai-compatible, base_url: https://token-plan.maas.qwencloudapi.com/compatible-mode/v1, model: qwen4-max, effort: high}` to .kogen/models.yaml. The Singapore pay-as-you-go base URL is https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1. An honesty note says Token Plan terms restrict automation and non-interactive batch use and that the Chat Completions route does not yet stream. messages-compatible is not mentioned. docs/configuration.md gains one link and names claude-code and QwenCloud. packaging/package.sh copies docs/providers.md into the archive docs folder, so the setup command `sh packaging/package.sh` still passes packaging/check-archive.cjs now that docs/configuration.md links to the guide. One new Go test file in the cli package reads the accepted names from cli/main.go and checks the table. No provider behaviour, login code or help text changes, and no existing sentence of README.md or docs/configuration.md is removed.

## Decisions
- The comparison table has one row per accepted provider name and the five columns Provider, Account or key needed, Roles verified, Built in or custom endpoint, Setup. (evidence: cli/main.go) (source: request)
- The accepted names are read by the Go test from the unknown-provider message in cli/main.go, since no exported list exists. (evidence: cli/main.go) (source: request)
- In the Roles verified cell, each role marked verified names a qualification record path in the same row that exists in the repository, and each role without such a record is written as not qualified. (source: request)
- Only records in spec/reference/model-family-qualification.md count: chatgpt Shape, Build and Review, and anthropic Review are verified; every other role, including every role of supergrok, opencode-go, claude-code and openai-compatible, is not qualified. (decision: D4, round 1) (evidence: spec/reference/model-family-qualification.md) (source: request)
- The QwenCloud subsection carries the exact label, the login command, the .kogen/models.yaml build line with the Token Plan base URL, the Singapore pay-as-you-go base URL, a sentence naming Token Plan terms and pay-as-you-go, and the statement that the Chat Completions route does not yet stream with the 45 second first-byte watchdog. The section says the label is not a qualification record. (decision: D5, round 1) (source: request)
- docs/providers.md uses plain backtick paths for qualification records, not Markdown links, and no emoji; the words works and supported do not appear, so no unqualified claim is made. messages-compatible is not mentioned. (decision: D6, round 1) (evidence: packaging/check-archive.cjs) (source: request)
- packaging/package.sh copies docs/providers.md in the existing docs copy line, because docs/configuration.md will link to it and the archive check fails `sh packaging/package.sh` on a linked missing file. No wrong implementation omits that copy. (decision: D7, round 1) (evidence: packaging/package.sh; packaging/check-archive.cjs) (source: request)
- Acceptance observes the docs and the packaging script directly in JavaScript and checks only that some cli test file reads docs/providers.md and main.go, because the Go test name is not fixed. (decision: D8, round 1) (source: request)
- controls.json is deferred: the correct implementation spans a new page, a Go test and three edited files. The wrong implementations were exercised in a scratch copy and each failed its named step. (decision: D9, round 1) (assumption: deferral is accepted for a multi-file documentation change) (source: request)
- Comparison table has one row per accepted provider name with five fixed columns (decision: D1, round 1) (constraint: names read from the unknown-provider message) (evidence: cli/main.go) (source: request)
- Only roles with a record in spec/reference/model-family-qualification.md are verified: chatgpt Shape, Build, Review and anthropic Review (decision: D2, round 1) (evidence: spec/reference/model-family-qualification.md) (assumption: claude-code has no record in this repository, so it is marked not qualified) (source: request)
- controls.json is deferred; the wrong implementations were exercised in a scratch copy outside the checkout (decision: D3, round 1) (assumption: deferral rests on the change spanning several files) (source: request)

## Source comparison
- Addressed: the six provider names, the table columns, the verified-needs-record rule, the QwenCloud label, both base URLs, the setup lines, the honesty note, the README link, the configuration.md link and names, and the package.sh copy (source: request; contract: docs/providers.md).
- Omitted by request: messages-compatible is not documented; no provider behaviour, login code or help text changes.

## Tests
- Every accepted name has a row in the table: a Go test in cli plus the acceptance step (unit)
- A verified role needs an existing record, with a rejected fixture and the real page accepted: a Go test in cli plus acceptance steps (unit)
- The QwenCloud label, both base URLs and the Token Plan and pay-as-you-go sentence: a Go text test plus acceptance steps (unit)
- README.md and docs/configuration.md link to the guide: acceptance steps (scenario)
- package.sh copies the guide into the archive docs folder: acceptance step (scenario)

## Feasibility
- none
