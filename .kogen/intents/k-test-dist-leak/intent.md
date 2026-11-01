# Isolate test release artifacts

Slug: k-test-dist-leak
Model: not applicable — this fixes test filesystem isolation, not a product state machine
Acceptance:
- .kogen/intents/k-test-dist-leak/acceptance.feature
- features/steps/k_test_dist_leak_steps.js

Tests must leave the checkout as they found it. Anything a Go test packages or installs belongs in that test's temporary directory. Fix cli/usage_limit_installed_test.go without losing its installed-CLI usage-limit/resume proof. Also fix the same root-packaging behavior in cli/build/baseline_installed_test.go. Do not change packaging's public output location or add a command, flag, option, timeout, retry or limit. Temporary source copies are an available internal test technique; preserve current-tree bytes rather than silently building HEAD.

The acceptance suite must install the release built from the current tree, not a synthetic usage-limit release. Existing explicit KOGEN_ARCHIVE selection and ordinary packaging remain supported. Do not solve contamination by deleting checkout dist files after a test or by filtering only the two known synthetic versions: tests must never write there, including while running. Preserve preexisting artifacts, tracked files, untracked files and source changes.

## Decisions
- No new user interface or configuration; retain usage-limit round 2 and round 3 installed behavior and existing baseline installed coverage. (source: request)
- Approval uses focused regression tests; the complete non-live suite is a delivery measurement after landing, not an approval command squeezed into 120 seconds. Every command run by approval retains its existing 120 s per-step limit. (source: request)

## Source comparison
- Addressed: request K-TEST-DIST-LEAK's root invocation `sh packaging/package.sh --version usage-limit-round<N>` and resulting `dist/kogen-usage-limit-round2-darwin-arm64.tar.gz` and round3 archive are replaced by test-owned temporary packaging, in the outcome above and isolation scenarios.
- Addressed: the 1 Nov 2026 ecde7c0 recheck reported installed `kogen usage-limit-round2 (2026-11-01)` rather than the real release. The regression requirements below preserve the current release bytes and default release selection; delivery reruns all three reported cases, including both examples at spec/features/09-cli-and-process.feature:312 and :313 and spec/features/10-install-and-uninstall.feature:10.
- Addressed: unchanged git status after `(cd cli && go test ./...)`, dist containing only intentional packaging output, temporary installation, and unchanged usage-limit proof are required below. The discovered baseline installed test has the same violating behavior and is included by the request's all-tests guarantee.
- Addressed: no new command/flag/option or timing/retry/limit changes. Full-suite evidence is explicitly assigned to delivery as requested; it is not claimed by focused approval evidence. No requested behavior is deliberately omitted or superseded.

## Tests
- Tests package and install without writing in the checkout: add TestUsageLimitPackagingIsolationRound2 and TestUsageLimitPackagingIsolationRound3 in cli, exercising the real installed workflow for each round and checking filesystem isolation (regression)
- Baseline installed packaging also stays temporary: add TestBaselinePackagingIsolation in cli/build, exercising its real installed workflow (regression)
- Installed usage-limit stop, checkpoint, preserved partial work, fresh resumed session, verification, review, lineage and single landing commit remain intact: keep TestUsageLimitResumeInstalledRound2 and TestUsageLimitResumeInstalledRound3 assertions (existing)
- The current-tree release remains available to acceptance: isolation regressions snapshot checkout git status and dist entries/content before execution and compare afterward, including a preexisting release and a non-release sentinel in a disposable checkout; observe no writes outside test temporary packaging during execution, not just cleanup afterward (integration)
- Three reported installed version scenarios pass without selecting a synthetic release: after landing run `(cd cli && go test ./...)`, compare git status and dist to their before snapshots, then run `sh test/suite.sh` and retain the complete non-live acceptance results for both "Version works anywhere without a login" examples and "Install into the default prefix and run from anywhere without Erlang, Elixir or Go" (scenario)

Implement the named isolation regressions with real local filesystem and packaging/install execution, not source-text assertions or skipped tests. Reuse installed workflows rather than duplicating their protocol assertions. Use disposable checkout/source fixtures to seed a current release and sentinel without modifying the caller checkout. Include noncommitted current-source bytes in packaging evidence. A regression must fail on the original root-packaging behavior. Do not recursively invoke go test ./... from a Go test. Keep the focused approval command within 120 seconds; optimize/reuse fixture work where needed without weakening assertions. Full-suite delivery timing is measured separately, with no limit changes.

## Feasibility
- none
