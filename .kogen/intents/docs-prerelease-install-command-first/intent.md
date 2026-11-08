# Put prerelease install commands first

Slug: docs-prerelease-install-command-first
Model: not applicable — documentation copy has no meaningful state
Acceptance:
- .kogen/intents/docs-prerelease-install-command-first/acceptance.feature
- features/steps/docs-prerelease-install-command-first__copy.js

Update README.md Install and docs/getting-started.md step 1 so a fresh agent can install a published prerelease without guessing a URL or building source. Put the latest installer command first, followed by the chosen-tag form. Retain installation into ~/.local without administrator rights, checksum verification where already described, version checking and the existing onboarding flow. Change documentation only; do not change installer behavior or release infrastructure.

## Decisions
- Start both install sections with `curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh` and show `curl -fsSL https://github.com/KogenAI/kogen/releases/latest/download/install-kogen.sh | sh -s -- --version <tag>` as the chosen-tag alternative; explain replacing `<tag>` with a release tag from https://github.com/KogenAI/kogen/releases. (source: request)
- List `darwin-arm64`, `darwin-x86_64`, `linux-x86_64`, and `linux-arm64` in both sections, with human-readable macOS Apple Silicon/Intel and Linux x86-64/ARM64 descriptions; retain the Linux glibc qualification. (source: request)
- Say the installer prints an 'Add to PATH' line when `~/.local/bin` is not on `PATH`, and retain actionable PATH guidance. (source: request)
- Move source-build instructions below the release installation instructions as a contributor route, retaining the existing source prerequisites and commands rather than removing that route. (source: request)

## Source comparison
- addressed: request problem (README Install lines 5–18 and getting-started step 1 omit a copy-paste release command, causing an agent to conclude there were no releases) is replaced by Decisions 1 and executable command/order scenarios for both files; retain the development-prerelease release-page context.
- addressed: request's four-platform mismatch with packaging/install-kogen.sh:19 is covered by Decision 2 and executable platform cases, replacing the two-platform README claim.
- addressed: request's 'Add to PATH' guidance and contributor-route ordering are covered by Decisions 3–4 and executable copy/order cases. Existing source commands, Go 1.27, Node 24, .tool-versions and mise remain in README's contributor route.
- addressed: request acceptance 'any docs link check passes' requires keeping existing checks passing and all introduced links valid; this change needs no new external link checker or network installation test.
- addressed: Studio issue 34bd9d61-f8ab-4b70-82bc-f8ee0b7eb02b identifies this documentation fix; no unrelated CLI or packaging changes are included.
- addressed: retry instructions require request-sourced Decisions and no probe output in this package; all Decisions above cite the request. No product question remains.

## Tests
- Both install sections expose the exact latest and chosen-tag commands before source builds: literal and ordering scenarios on actual Markdown files (regression)
- Both install sections list all four installer platforms and explain PATH guidance: literal copy scenarios on actual Markdown files (regression)
- Source builds remain below release installation as the contributor route: ordering and contributor-copy scenarios (regression)
- Existing documentation links and surrounding onboarding remain valid: retain configured checks and review changed links (existing)

## Feasibility
- none
