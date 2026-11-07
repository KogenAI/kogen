# Document unattended provider sign-in

Slug: docs-unattended-sign-in
Model: not applicable — documentation has no meaningful state
Acceptance:
- .kogen/intents/docs-unattended-sign-in/acceptance.feature
- features/steps/docs-unattended-sign-in__copy.js

Add a short “Without a browser (scripts, agents, remote shells)” block within step 3 of docs/getting-started.md. Show stdin login for Anthropic and Claude Code, explain that a person supplies the secret and that the Claude Code token comes from claude setup-token. Explain that ChatGPT requires a browser on the same machine at port 1455 and has no unattended form. Preserve the existing browser route and configuration-first guidance. This is documentation only; do not change authentication behavior or obtain secrets.

## Decisions
- Place the new block in step 3; the README install example remains valid and already links to the guide. No README expansion is required by the requested expected outcome. (evidence: README.md; docs/getting-started.md) (source: request)
- Use ANTHROPIC_API_KEY and CLAUDE_CODE_TOKEN as human-supplied shell variables; the latter contains the token made with claude setup-token. Both login routes consume standard input, consistent with provider help. (evidence: cli/main.go) (source: request)

## Source comparison
- Addressed: issue 79b6b424-520c-4c7a-b4bf-4fec98988fe9 asks for a step 3 browserless block, both printf pipelines, human-supplied secrets and the ChatGPT same-machine port 1455/no-unattended limitation; all are required here and in acceptance.feature.
- Addressed: commands must match kogen provider --help; cli/main.go providerPage documents anthropic API key and claude-code setup-token input on stdin. No provider integration is changed.
- Omitted deliberately: expanding README's install block, which the problem mentions but the expected outcome and acceptance target only docs/getting-started.md. Its existing browser command and guide link remain unchanged.
- Addressed as motivation, not new runtime behavior: without a browser ChatGPT waits on 127.0.0.1:1455; absent piped input the other routes print 'input interrupted; saved login unchanged'. The documentation must direct agents to human-supplied stdin secrets rather than promise an unattended ChatGPT fallback. No secret acquisition or login execution belongs in these tests.

## Tests
- Browserless sign-in guidance: inspect the step 3 Markdown for the heading, pipelines and explanatory copy (regression)

## Feasibility
- none
