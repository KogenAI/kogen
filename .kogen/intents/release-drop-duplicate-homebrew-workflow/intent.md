# Drop the duplicate Homebrew workflow

Slug: release-drop-duplicate-homebrew-workflow
Model: not applicable — deletion of release wiring, no application state
Acceptance:
- .kogen/intents/release-drop-duplicate-homebrew-workflow/acceptance.feature
- features/steps/release-drop-duplicate-homebrew-workflow__steps.js

Kogen Delivery's release publication already updates the KogenAI/homebrew-tap formula with signed commits. The workflow `.github/workflows/homebrew.yml` and `packaging/update-homebrew.sh` duplicate that update, need a missing `HOMEBREW_TAP_TOKEN` secret, and would push unsigned commits. Remove both files, and remove everything under the `release-updates-brew-formula-and-docs` Intent that only exists to test them: its directory `.kogen/intents/release-updates-brew-formula-and-docs/` (intent.md, acceptance.feature, controls.json), `features/steps/release-updates-brew-formula-and-docs__steps.js` and the directory `features/steps/release-updates-brew-formula-and-docs__driver/`. README.md's Homebrew install section (`brew install KogenAI/tap/kogen` and the supported platforms) stays unchanged. No other files change. `.github/workflows/release.yml` stays.

## Decisions
- Delete the workflow, script and the old Intent's acceptance artifacts entirely, with no replacement. (evidence: .github/workflows/release.yml; .kogen/intents/release-updates-brew-formula-and-docs/intent.md) (source: request)
- README.md is not edited; the install command it documents is `brew install KogenAI/tap/kogen` (the README currently spells the tap lowercase, `kogenai/tap/kogen`, which Homebrew treats identically), so acceptance matches case-insensitively. (evidence: README.md) (source: request)

## Source comparison
- addressed: removal of homebrew.yml, update-homebrew.sh and the old Intent's step files, driver and controls; acceptance checks each is absent.
- addressed: README keeps `brew install KogenAI/tap/kogen` (matched case-insensitively) and its platforms line.
- addressed: no workflow triggers on release publication and references homebrew-tap.
- omitted: the tap itself and Kogen Delivery are outside this repository.

## Tests
- Removed files are gone: scenario checking the deleted paths do not exist (scenario)
- No release-triggered workflow pushes to the tap: scenario scanning .github/workflows (scenario)
- README still documents the brew install: scenario reading README.md (scenario)
- Repository tests still pass: the configured checks (existing)

## Feasibility
- none
