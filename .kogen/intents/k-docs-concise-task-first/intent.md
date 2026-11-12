# Rewrite README and docs short and task-first

Slug: k-docs-concise-task-first
Model: not applicable — documentation only, no state
Acceptance:
- .kogen/intents/k-docs-concise-task-first/acceptance.feature
- features/steps/k-docs-concise-task-first__docs.js

README.md and docs/ become short, task-first user documentation. README.md is under 80 lines. docs/ holds getting-started.md (under 150 lines), configuration.md (under 120 lines), troubleshooting.md and the unchanged testing-rules.md, nothing else. overview.md, usage.md, using-kogen.md, checkout-facts.md, contributing.md and executor-contract.md are merged into those files, moved into spec/ if useful and absent from docs/, or deleted. The internal notes check-time-measurements.json, k-acceptance-fixed-wait.md, kogen-066-loop-change.md, round-targeted-tests.md, model-family-qualification.md, testing-strategy.md, readiness-and-custody.md, evidence/ and presets/ leave docs/; anything still useful moves into spec/, the rest is deleted. Nothing moves outside spec/. No docs/ file restates spec/. The rest of the repository (Go code, tests, spec/) is unchanged apart from files moved into spec/. The one packaging edit is in packaging/package.sh: it copies docs/usage.md, docs/model-family-qualification.md and docs/presets into the release archive, which no longer exist, so those copies are removed and it ships the four remaining docs files; nothing about docs/testing-rules.md changes there. The Build runs no Kogen command; every output shown comes from this Intent.

README.md: what Kogen is (3 lines); install with `curl -fsSL https://get.kogen.dev | sh` (redirects to the release installer) and Homebrew `brew trust kogenai/tap && brew install kogenai/tap/kogen` with one sentence why (Homebrew 7 does not load formulae from third-party taps until the tap is trusted), no release version in the Homebrew route; platforms macOS arm64 and x86-64, Linux x86-64 and arm64; a link to https://kogen.dev/get-started/ for the full install page; a 5-command quickstart (init, provider login, shape, approve, build) with real output of the first and last; the agent line "make changes through `kogen intent shape`, `approve` and `build`"; links to docs/ and spec/.

getting-started.md: install to the first landed Build; every command followed by its real output as a fenced block, using literals below; after `kogen init` it says to run `kogen intent shape <slug> <request-file>`. Real outputs (release v0.1.0-dev.62015185):

- `kogen version`: `kogen v0.1.0-dev.62015185 (2026-11-07)`.
- `kogen init` in a Git repository with a signed-in Claude Code login: `Initialized Kogen in <path>`, `Setup: none`, `Fix: none`, `Checks: tests`, `Protect: none`, `Acceptance: Cucumber bridge added in features/steps`, `Commit: 1eb6a4ca Add Kogen configuration`, `ok install - kogen v0.1.0-dev.62015185 (2026-11-07); node, cucumber and quint run`, `ok git - repository <path>`, `ok config - .kogen/project.yaml is valid`, `ok models - shape, build, review ready`.
- `kogen provider list`: `claude-code: token saved (not verified)`, then `claude-code runtime: Claude Code <pinned version> installed (<home>/.kogen/claude-code/2.1.312/claude)`; a fresh home has no claude-code row.
- `kogen intent shape <slug> request.md` ends with `Intent: <path>/.kogen/intents/<slug>/intent.md`, `Acceptance test: <path>/.kogen/intents/<slug>/acceptance.feature`, `Step files: features/steps/<slug>__calc.js (new)`, `Model: not applicable - <reason>`, `Scenarios: 5 (4 fail now, 1 pass now)`, `Next: kogen intent approve <slug>`.
- `kogen intent approve <slug>` ends with `Next: kogen intent build <slug>`.
- `kogen intent build <slug>`: `building <slug>`, `kogen: building (round 1)`, `kogen: verifying (pass 1)`, `kogen: pass 1: all checks passed`, `kogen: reviewing (review 1)`, `kogen: review 1: approve, 0 blocking`, `kogen: committing`, `landed <slug> 03c89ee0 (Build e9acffc6)`, `  checks: acceptance 5/5, model not applicable, tests passed`, `  review: approved`.
- The no-login refusal of `kogen init` is shown with its sign-in routes: `provider/login: not signed in; run kogen provider login for a supported provider`, then browser sign-in `kogen provider login chatgpt` and, with no browser, an Anthropic API key on standard input. Init discovery needs no ChatGPT login when another route (for example an Anthropic key) is available.
- `kogen uninstall` is shown with its command in a fenced block; it keeps logins and `.kogen/host-id`.
- `setup-token` for Claude Code needs the Claude Code runtime that only the first role installs; the page says so where it uses it.

configuration.md: the two files .kogen/project.yaml and .kogen/models.yaml with its override .kogen/local/models.yaml; for each one annotated fenced example and one short line per key; one idea per line, no line over 160 characters. Edge-case detail not in spec/ goes to spec/, otherwise it is dropped.

troubleshooting.md: for each code, the exact message, what it means and the exact next command where Kogen gives one: `environment/not_a_git_repo: <path>; run git init first`; `environment/git_identity_missing: no Git user.name and user.email; run git config user.name "<name>" and git config user.email "<email>" (global or repository)`; `environment/not_initialized: <root> has no .kogen/project.yaml; run kogen init`; `provider/login: not signed in; run kogen provider login for a supported provider` with its routes; `candidate/recovery_unsupported` and `candidate/resume_unsupported` ("<id>" is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; `kogen intent list` lists Build attempts); `intent/not_found: Intent does not exist` from refine, approve and build, which names no next command; outside a project `kogen intent inspect <id>` answers JSON with `not_project` (inside a project it names `kogen intent list`); `setup_failed ... go: command not found` when shaping in a non-Go repository. Where Kogen's behaviour is wrong (`--help` printing the group listing, the multi-line no-login refusal, `intent/not_found` without a next command, the `setup_failed` case, raw `not_project` JSON, a `kogen: shape time` line after an environment refusal) the docs state what it does today and describe no fix. Also stated as facts: `kogen version` prints `kogen v0.1.0-dev.<sha> (<date>)`.

Style: every doc says what Kogen does and how to use it; no sentences about what it refuses or does not do unless the user must act on them. Every relative link in README.md and docs/ resolves to an existing file. docs/testing-rules.md stays in place, byte-identical.

## Decisions
- docs/ holds exactly getting-started.md, configuration.md, troubleshooting.md and testing-rules.md; no user-facing preset is kept. (decision: D1, round 1) (evidence: docs/testing-rules.md; docs) (source: request)
- The rest of the repository (Go code, tests, spec/) is unchanged apart from files moved into spec/. (decision: D2, round 1) (source: request)
- Acceptance steps read docs only in Then steps and take literals from the feature file. (decision: D3, round 1) (source: request)
- packaging/package.sh drops its copies of the removed docs/usage.md, docs/model-family-qualification.md and docs/presets so the release archive still builds; this is the only non-doc edit. (decision: D4, round 1) (evidence: packaging/package.sh) (assumption: the request lists Go code, tests and spec/ as unchanged, not packaging, and removing those docs files requires this edit) (source: request)

## Source comparison
- README, getting-started, configuration, troubleshooting targets, merges, removals and spec/ moves: addressed (source: request; .kogen/intents/k-docs-concise-task-first/acceptance.feature).
- Retry note keeping docs/testing-rules.md unchanged supersedes the request's removal of testing-rules.md: addressed (source: request).
- Behaviour fixes for W3, W5, W7, W11, W12, W13: omitted, documented as current behaviour only (source: request).

## Tests
- README, docs size, content and inventory targets: acceptance.feature scenarios on README.md and docs/ (scenario)
- Relative links resolve, and no code, test or spec rewrite: separate link and working-tree scenarios (scenario)
- Release archive still builds with the reduced docs: existing go-test check (existing)

## Feasibility
- none
