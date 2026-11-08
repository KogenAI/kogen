# Document that init works without ChatGPT

Slug: docs-init-works-without-chatgpt
Model: not applicable — documentation has no meaningful state
Acceptance:
- .kogen/intents/docs-init-works-without-chatgpt/acceptance.feature
- features/steps/docs-init-works-without-chatgpt__copy.js

After the provider selection change, `kogen init` works with a Claude Code token or an Anthropic key alone (it prints `kogen: selected claude-code for discovery and shape, build and review` and `ok models - shape, build, review ready`). The docs still say init discovery needs a ChatGPT login and lead every install path to the ChatGPT sign-in, so a fresh agent told its human it needed ChatGPT. Correct README.md, packaging/README.md and docs/getting-started.md. This is documentation only; no program behavior changes.

Required outcome:
- docs/getting-started.md steps 3 ("Log in") and 4 ("Initialise the project") each say that `kogen init` discovery works with any signed-in route. The sentence that discovery needs a ChatGPT login is removed.
- Step 4 says that Without ChatGPT is the optional hand-written path, and says that `ok models - shape, build, review ready` means the next command is `kogen intent shape <slug> <request-file>`.
- README.md and packaging/README.md replace the single ChatGPT login line with the three routes: browser (`kogen provider login chatgpt`), Anthropic key on stdin, and Claude Code token on stdin, introduced as any one of these routes.
- Line 3 of packaging/README.md drops 'with your ChatGPT plan'.
- None of the three files claims that init needs ChatGPT.

## Decisions
- Edit only README.md, packaging/README.md and docs/getting-started.md; docs/configuration.md also says bare init requires ChatGPT, but the request scopes the correction to these three files. (decision: D1, round 1) (constraint: Do not change any file outside the three docs) (evidence: README.md; packaging/README.md; docs/getting-started.md; docs/configuration.md) (source: request)
- The three routes are the browser ChatGPT login `kogen provider login chatgpt`, `printf '%s' "$ANTHROPIC_API_KEY" | kogen provider login anthropic` and `printf '%s' "$CLAUDE_CODE_TOKEN" | kogen provider login claude-code`, introduced by the phrase 'any one of these routes' in README.md and packaging/README.md. (decision: D2, round 1) (constraint: Both README files list all three commands) (evidence: docs/getting-started.md) (source: request)
- The request's statement that init works with a Claude Code token or Anthropic key alone after k-init-provider is taken as stated. This shaping found no code that prints the selection line. (decision: D3, round 1) (assumption: Not verified against cli source; the docs only describe the behavior.) (source: request)
- The new copy keeps the exact phrases the acceptance checks: 'discovery works with any signed-in route' in steps 3 and 4, 'Without ChatGPT is the optional hand-written path' and the next-command sentence in step 4, and the exact line 3 of packaging/README.md. (assumption: the user accepts this fixed wording) (source: request)
- Step 3 of docs/getting-started.md keeps its three existing login commands, since they are already the three routes; the request only changes the claims around them. (evidence: docs/getting-started.md) (assumption: the user confirms step 3 keeps the three login commands unchanged) (source: request)

## Source comparison
- Addressed: getting-started steps 3 and 4 say discovery works with any signed-in route; 'Without ChatGPT' is the optional hand-written path; the next-command sentence is present (request; acceptance scenarios 1 and 2).
- Addressed: README.md and packaging/README.md list the three routes instead of the single ChatGPT line (scenarios 3 and 4). In the checkout the README.md ChatGPT login is at line 49 and the packaging/README.md one at line 22; the request's line numbers differ for README.md.
- Addressed: packaging/README.md line 3 drops 'with your ChatGPT plan' (scenario 5).
- Addressed: no claim that init needs ChatGPT remains in the three files (scenario 6).
- Omitted deliberately: docs/configuration.md lines 202-203 also say bare init requires ChatGPT; outside the request's three files.

## Tests
- Getting-started steps 3 and 4 say discovery works with any signed-in route, and step 3 keeps the three login commands: inspect the step Markdown (regression)
- Step 4 names the optional hand-written path and the next command: inspect the step 4 Markdown (regression)
- README.md and packaging/README.md list the three routes: inspect the Markdown (regression)
- packaging/README.md line 3 no longer mentions ChatGPT: compare the exact line (regression)
- No file claims init needs ChatGPT: scan the sentences of the three files (regression)

## Feasibility
- none
