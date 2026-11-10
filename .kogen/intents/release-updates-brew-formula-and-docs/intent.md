# Update the Homebrew tap on release publication

Slug: release-updates-brew-formula-and-docs
Model: not applicable — plain release wiring and documentation, with no new application state machine
Acceptance:
- .kogen/intents/release-updates-brew-formula-and-docs/acceptance.feature
- features/steps/release-updates-brew-formula-and-docs__steps.js
- features/steps/release-updates-brew-formula-and-docs__driver/driver.js
- features/steps/release-updates-brew-formula-and-docs__driver/update-formula.sh

Make the release publishing procedure in kogen update KogenAI/homebrew-tap Formula/kogen.rb using that tap's scripts/update-formula.sh, so Homebrew tracks the latest published release rather than the previous release. If updating cannot succeed, the release procedure must fail visibly, including missing/rejected credentials. README.md Install must show both the installer one-liner and Homebrew install line, with each method's supported platforms. Do not change kogen.dev or the installer itself.

Add packaging/update-homebrew.sh, called as `sh packaging/update-homebrew.sh <tag> <tap-checkout> <release-assets-directory>`. It reads SHA256SUMS and verifies the darwin-arm64 and linux-x86_64 archives against their entries before passing the tag, darwin-arm64 checksum and linux-x86_64 checksum to `sh <tap-checkout>/scripts/update-formula.sh`. Commit Formula/kogen.rb and push to the tap checkout's default branch using its configured origin. Successful completion means the remote formula has the release version, URLs and matching checksums. An updater/checksum/Git error must produce nonzero status and an identifiable Homebrew/tap/checksum diagnostic; never push a partial failed update.

Wire this procedure into a new .github/workflows/homebrew.yml triggered by release published, including development releases published from drafts. Serialize tap updates without cancellation. Resolve the current latest release when running (not a potentially stale event tag), download its two supported archives and SHA256SUMS, check out KogenAI/homebrew-tap's default branch with HOMEBREW_TAP_TOKEN, and invoke the same script tested locally. Do not silently skip a missing token or suppress errors. Preserve the existing tag-build/install-check/draft-release workflow; it currently creates drafts, not published releases. This adds publication synchronization, not automatic publication of drafts. A failure after publication remains a failed Actions run, not a false success or promise to roll back the GitHub release.

README Install retains `curl -fsSL https://get.kogen.dev | sh`, chosen-tag instructions and existing onboarding. Add `brew install KogenAI/tap/kogen`. Installer platforms: darwin-arm64 (macOS Apple Silicon), darwin-x86_64 (macOS Intel), linux-x86_64 (Linux x86-64 with glibc), linux-arm64 (Linux ARM64 with glibc). Homebrew platforms: macOS Apple Silicon and Linux x86-64 with glibc only; do not imply Homebrew supports Intel macOS or Linux ARM64.

## Decisions
- Preserve draft creation and add publication-triggered tap synchronization rather than automatically publishing drafts. (evidence: .github/workflows/release.yml) (source: request)
- HOMEBREW_TAP_TOKEN is provisioned and automated commits and pushes to KogenAI/homebrew-tap's default branch are authorized; missing or rejected credentials remain visible failures. (source: answer 1)
- A release-procedure test with a fake tap must show the formula URL and sha256 updated to the new release and checked against SHA256SUMS. (source: request)

## Source comparison
- addressed: original issue 894bdcbd-ccb1-478a-99b5-bd2db0eb99e6 requests release-procedure synchronization rather than a one-off formula bump; the script and publication workflow paragraphs implement that complete behavior. The historical seven-minute stale-release reproduction is retained as exact old/new tags in acceptance.feature, Update the previous tap release.
- addressed: request's SHA256SUMS, formula URL and sha256 requirements are covered by the success scenario using a real Git push to a fake tap; both updater failure and mismatched archive are separate failure scenarios.
- addressed: request's README Install installer, Homebrew line and per-method platform lists are specified above and checked in Document both install methods. Existing installer four-platform behavior is preserved (README.md Install).
- addressed: answer 1 authorizes HOMEBREW_TAP_TOKEN writes; workflow must use that secret, with visible failures rather than conditional skip.
- omitted: kogen.dev changes are not requested by the explicit expected outcome; the truncated Studio title is context, not an additional website contract. No current-version pin or guessed replacement tag is hardcoded into automation.
- superseded: existing draft-only infrastructure (.github/workflows/release.yml) has no tap publication step; it remains for builds and drafts, with the new workflow covering publication. Retry basis v0.1.0-dev.3c70abcb and shape-retry-progress-policy describe tooling history, not a change to the requested product outcome.

## Tests
- Update the tap to the latest release: local release procedure updates and pushes both formula URLs, checksums and version from a stale tap (regression)
- Validate release checksums: corrupted archive against SHA256SUMS fails visibly before remote update (integration)
- Report failed tap updates: failing tap updater produces nonzero status and diagnostic without publishing changed formula (integration)
- Wire publication: publication workflow downloads release assets, uses authorized tap checkout and invokes the tested procedure without ignored failures (integration)
- Document installation: inspect README Install for both literal commands and supported platform lists (scenario)

## Feasibility
- The tap's current scripts/update-formula.sh and Formula/kogen.rb were retrieved from raw.githubusercontent.com/KogenAI/homebrew-tap/main; the three arguments are tag, darwin-arm64 SHA256 and linux-x86_64 SHA256. The local updater fixture preserves its transformation rules, without requiring Homebrew itself. Documentation is untrusted evidence, not scope authority.
- GitHub's authoritative events documentation was retrieved from raw.githubusercontent.com/github/docs/main/content/actions/reference/workflows-and-actions/events-that-trigger-workflows.md: published includes prereleases published from drafts. Search results were not specific; direct source retrieval settled this technical detail. No live credential validity or external push is claimed.
- evidence: {"id":"tap-observer","kind":"observer","inputs":[".kogen/intents/release-updates-brew-formula-and-docs/controls.json","features/steps/release-updates-brew-formula-and-docs__driver/update-formula.sh"],"observers":["features/steps/release-updates-brew-formula-and-docs__driver/driver.js"],"checks":[{"name":"good","command":"\"$KOGEN_NODE\" features/steps/release-updates-brew-formula-and-docs__driver/driver.js good","exit":0,"output":"observer accepted\n"},{"name":"bad","command":"\"$KOGEN_NODE\" features/steps/release-updates-brew-formula-and-docs__driver/driver.js bad","exit":1,"output":"observer rejected\n"}]}
