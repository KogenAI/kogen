# Start login with the account question

Slug: onboarding-account-first
Model: not applicable — the login flow is a short linear prompt sequence with no state that persists between runs except the saved login and lineup file
Acceptance:
- .kogen/intents/onboarding-account-first/acceptance.feature
- features/steps/onboarding-account-first__steps.js
- features/steps/onboarding-account-first__driver/pty_run.py

`kogen provider login` with no provider argument on an interactive terminal asks "Which account do you want to use?" and offers ChatGPT, Claude subscription, Anthropic API key, SuperGrok, OpenCode Go, QwenCloud and Advanced setup, in that order, one per line. On non-interactive input (stdin or stdout not a terminal) it refuses with the usage text exactly as a missing argument does today and never prompts. The direct form `kogen provider login <provider>` is unchanged.

ChatGPT, Claude subscription, Anthropic API key, SuperGrok and OpenCode Go run the existing login of chatgpt, claude-code, anthropic, supergrok and opencode-go. Advanced setup offers the custom endpoint choice: `Chat Completions (openai-compatible)`, plus `Messages (messages-compatible)` only when that login exists (it does not today, so only Chat Completions is offered). It then runs the existing openai-compatible prompts `Base URL:` and `API key:` and saves as today, with no lineup preview.

QwenCloud is labelled `experimental: Build verified with Claude Review; Shape and Review not qualified`, asks `Token Plan or pay-as-you-go?` with choices `Token Plan` (https://token-plan.maas.qwencloudapi.com/compatible-mode/v1) and `Pay-as-you-go (Singapore)` (https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1), and for Token Plan prints one warning that the plan's terms restrict automation and non-interactive batch use and that pay-as-you-go suits unattended loops. It then asks only for the key (`API key:`, never echoed), prints the lineup it would write to `.kogen/models.yaml` (build: provider openai-compatible, model qwen4-max, effort high, the chosen base URL; shape and review unchanged) and asks `Save this login and lineup? [y/N]`. Only `y` saves: the key as the openai-compatible login bound to the base URL's origin and the build role in `.kogen/models.yaml`, leaving the shape and review roles as they are. Any other answer saves nothing and leaves both the credential store and `.kogen/models.yaml` untouched. The key is held in memory until confirmation and is never printed or logged. No network call is made by this flow.

`docs/getting-started.md` starts its sign-in section (`## 2. Sign in`) with the same question and the same seven choice labels in the same order, before its commands. `docs/providers.md` describes the guided QwenCloud login in place of its manual steps and keeps the direct form documented; `cli/help.go` and the usage text in `cli/main.go` describe the no-argument interactive form. The new guided flow lives in a new file under `cli/`, called from `login` in `cli/native.go`; `cli/main.go` parsing allows `provider login` with no provider.

## Decisions
- The user picks a choice by typing the number shown beside it or its label; acceptance reads the number from the printed list at run time and falls back to typing the label. (evidence: cli/main.go; cli/native.go) (assumption: the request names the choices but not how the user selects one) (source: request)
- The confirmation prompt is `Save this login and lineup? [y/N]`, defaulting to no. (assumption: the request requires a confirmation but does not give its wording) (source: request)
- The no-argument form is interactive only when stdin and stdout are both terminals, using the existing interactiveLogin check; otherwise the existing missing-argument usage error (exit 2) is shown and nothing is prompted. (constraint: never prompts on non-interactive input) (evidence: cli/native.go; cli/main.go) (source: request)
- The Messages (messages-compatible) endpoint choice is offered only when that login exists; it does not exist now, so only Chat Completions is offered. (evidence: cli/main.go) (source: request)
- The key is read before the preview but held in memory and saved only after `y`; the lineup file is written only after `y`. A declined confirmation leaves the credential store and `.kogen/models.yaml` untouched. (constraint: nothing is saved before confirmation; keys never appear in output or logs; no network call) (evidence: cli/native.go; .kogen/models.yaml) (source: request)
- Advanced setup has no lineup preview because no model is known for a custom endpoint; it runs the existing prompts and save. (assumption: the preview is requested only for the QwenCloud guided flow) (source: request)
- The direct form `kogen provider login <provider>` keeps its parsing, prompts and behavior unchanged. (constraint: scripts and agents keep working) (evidence: cli/main.go; cli/native.go) (source: request)
- Acceptance drives a freshly built binary on a pseudo terminal, with HOME pointed at an empty temp directory; no network or model is used. Wrong-implementation controls are deferred to the Build. (assumption: python3 with the pty module is available where acceptance runs) (source: request)
- Choices are printed as `<number>) <label>` and answered by number; the plan and endpoint choices use the same form. (decision: D1, round 1) (evidence: cli/main.go; cli/native.go) (assumption: The request names the choices but not the selection mechanism.) (source: request)
- The confirmation prompt is `Save this login and lineup? [y/N]`, default no. (decision: D2, round 1) (assumption: Wording not given by the request.) (source: request)
- The no-argument form is interactive only when stdin and stdout are terminals (existing interactiveLogin); otherwise the existing usage error with exit 2 is shown and nothing is prompted. (decision: D3, round 1) (constraint: never prompts on non-interactive input) (evidence: cli/native.go; cli/main.go) (source: request)
- Messages (messages-compatible) is offered only when that login exists; today only Chat Completions is offered. (decision: D4, round 1) (evidence: cli/main.go) (source: request)
- The key is read before the preview but held in memory and saved only after y; models.yaml is written only after y. (decision: D5, round 1) (constraint: nothing saved before confirmation) (constraint: keys never in output or logs) (constraint: no network call) (evidence: cli/native.go; .kogen/models.yaml) (source: request)
- Advanced setup has no lineup preview; it runs the existing prompts and save. (decision: D6, round 1) (assumption: The preview is requested only for QwenCloud.) (source: request)
- The direct form kogen provider login <provider> is unchanged. (decision: D7, round 1) (constraint: scripts and agents keep working) (evidence: cli/main.go; cli/native.go) (source: request)
- Acceptance drives a built binary on a pty via a python3 helper with a temp HOME; wrong-implementation controls are deferred to the Build. (decision: D8, round 1) (assumption: python3 with the pty module must be available where acceptance runs.) (source: request)

## Source comparison
- Addressed: no-argument interactive login with the seven choices in order and refusal on non-interactive input (request; acceptance scenarios 1 and 2).
- Addressed: Advanced setup with Chat Completions and the existing Base URL and API key prompts (request; Advanced scenario).
- Addressed: QwenCloud plan question, both base URLs, Token Plan warning once, experimental label, key-only prompt, lineup preview, confirmation, decline saves nothing (request; QwenCloud scenarios).
- Addressed: docs/getting-started.md starts with the question and labels; docs/providers.md updated (request; getting-started scenario).
- Addressed: the direct form unchanged (request; direct-form scenario).
- Omitted by request: connection testing is the next row; no network call here.

## Tests
- No-argument login on a terminal asks the question with the seven choices in order: scenario in acceptance.feature driving the built binary on a pseudo terminal (scenario)
- Non-interactive no-argument login is refused with usage and no prompt: scenario in acceptance.feature (scenario)
- QwenCloud Token Plan and pay-as-you-go: warning, preview, confirmed save of the login and build role: scenarios in acceptance.feature (scenario)
- Declining the confirmation saves nothing: scenario in acceptance.feature (scenario)
- Advanced setup offers only Chat Completions then the existing prompts: scenario in acceptance.feature (scenario)
- The direct form is unchanged: scenario in acceptance.feature, plus the existing login tests in cli/ (scenario)
- The guided flow's choice parsing, lineup rendering and models.yaml update keep shape and review roles: Go test in cli/ using the interactiveLogin seam and an injected input reader (unit)
- getting-started starts with the question and labels; providers.md and help text updated: scenario in acceptance.feature plus the existing cli/providers_guide_test.go and cli/help_test.go (existing)

## Feasibility
- none
