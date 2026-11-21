# Ship the Providers guide in archive mode checks

Slug: main-health-24169a
Model: not applicable — the change is a constant in a test observer; there is no state to model
Acceptance:
- .kogen/intents/main-health-24169a/acceptance.feature
- features/steps/main-health-24169a__steps.js

The scenario "Release archives own their public modes independently of copied inputs and caller umask" (spec/features/10-install-and-uninstall.feature, tag @INS-2) fails because its observer, features/steps/release_archive_public_modes.py, lists the docs that packaging/package.sh copies into the archive in `SHIPPED_DOCS` as getting-started.md, configuration.md, troubleshooting.md and testing-rules.md. Commit 131aac3 made packaging/package.sh also copy docs/providers.md, so the archive holds a docs/providers.md that the observer does not expect and the payload-paths comparison fails. The cause lives in this repository (the observer), not in another one. The fix is to add `providers.md` to `SHIPPED_DOCS` in features/steps/release_archive_public_modes.py, so the observer expects exactly the docs the release script copies. Nothing else changes: no change to packaging/package.sh or any release script, no new flag, setting or environment variable, no scenario removed, skipped or weakened, and no guard weakened (the payload paths, bytes, types, links and public modes are still all compared exactly).

The acceptance scenario is a model-free regression test of this repository that reads packaging/package.sh and the observer and fails on main today because the two lists of shipped docs differ.

## Decisions
- The cause is in this repository: the archive-mode observer's `SHIPPED_DOCS` lacks providers.md, which packaging/package.sh copies since the Providers guide was added; no other repository owns it. (decision: D1, round 1) (evidence: packaging/package.sh; features/steps/release_archive_public_modes.py; docs) (source: request)
- The fix adds `providers.md` to `SHIPPED_DOCS` in features/steps/release_archive_public_modes.py and leaves packaging/package.sh and the copied-input handling unchanged, because the request forbids changing the release scripts and the Providers guide is meant to ship. (decision: D2, round 1) (constraint: no change to packaging/package.sh; no new flag, setting or environment variable) (evidence: packaging/package.sh; features/steps/release_archive_public_modes.py) (source: request)
- The regression test compares the docs named on the `cp docs/... "$work/docs/"` line of packaging/package.sh with the observer's `SHIPPED_DOCS` as sets and does not run the offline npm packaging, because the full packaging run needs a prepared npm cache and is the assembly suite's job; the Build cannot run it. (decision: D3, round 1) (evidence: features/steps/release_archive_public_modes_steps.js; test/acceptance/support/public_archive_modes.py) (assumption: the cp-line comparison is accepted as the reproducing test instead of a full package run) (source: request)
- controls.json holds a patch of the correct one-line change and two wrong implementations, each exercised in a scratch copy and each failing its named step: a misspelled entry in the observer, and removing providers.md from the release script's copy line. (decision: D4, round 1) (source: request)

## Source comparison
- Failing scenario "Release archives own their public modes independently of copied inputs and caller umask" (spec/features/10-install-and-uninstall.feature:99): addressed by adding providers.md to the observer's shipped docs; the scenario itself is not edited.
- Candidate commit 131aac3 "Add a Providers guide that tracks the CLI": identified as the cause, since it added docs/providers.md to the copy line of packaging/package.sh; its behaviour is kept.
- Other candidate commits (kogen-build, kogen-loop, kogen-shaping, ae2153c): not related to archive modes; omitted.
- Constraints (no release script change, no new flag/setting/environment variable, nothing outside this repository): preserved.

## Tests
- The observer expects exactly the docs the release script copies into the archive, including docs/providers.md: a model-free Cucumber regression scenario in this Intent that reads packaging/package.sh and features/steps/release_archive_public_modes.py (regression)
- The public archive modes scenario in spec/features/10-install-and-uninstall.feature passes again on the new main tuple: unchanged existing scenario, run by the next main-health run (existing)

## Feasibility
- none
