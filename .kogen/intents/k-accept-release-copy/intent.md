# Reuse releases in installing acceptance scenarios

Slug: k-accept-release-copy
Model: not applicable — test-fixture allocation changes, not the install/upgrade/uninstall state machines already exercised by the suite
Acceptance:
- .kogen/intents/k-accept-release-copy/acceptance.feature
- features/steps/release_copy_steps.js
- features/steps/release_copy_observer.cjs

Remove per-installing-scenario full release-tree copies from acceptance support. Reuse the real archive extracted by BeforeAll; give mutations isolated, minimal private material rather than mutating shared release bytes. Keep actual installer execution and real release payloads in scenarios that prove installation. Shared installed prefixes may continue serving scenarios that do not test installation. This is test-only: no production CLI, installer, command, flag, option, timeout, retry or limit changes.

The affected entry points are test/acceptance/support/handlers.js extractArchive and its callers, hooks.js suite extraction/install lifecycle, and world.js scenario cleanup. The missing lib/VERSION fixture removes both VERSION and VERSION.json today; preserve this intentional corruption without exposing it to other scenarios or workers. Preserve install, upgrade and uninstall assertions throughout the non-live suite, with no skips or weakening. Shared assets must outlive scenarios and be cleaned by suite ownership, not scenario cleanup. Support both existing target platforms and parallel workers.

## Decisions
- Reuse the extracted real release; isolate only scenario mutations and retain the existing behavior coverage. No particular sharing implementation is prescribed. (source: request)
- Approval runs chapter 10 once, within the unchanged 120-second acceptance-step limit, and prints before/after workspace file counts. Complete non-live suite is the delivery landing gate. (source: request)

## Source comparison
- Addressed: request K-ACCEPT-RELEASE-COPY's full-tree cpSync/COPYFILE_FICLONE allocation problem is replaced by shared release use, per outcome and regression scenario below. The 7,551 release entries, h08's 13,871 files per installing scenario, approximately 49k events/hour and 81% core are historical motivation, not portable count thresholds.
- Addressed: install, upgrade and uninstall remain real-release behavioral proofs, without skipping or weakening; Tests requires existing chapter plus full non-live landing coverage.
- Addressed: approval's 120-second limit remains unchanged. Acceptance executes spec/features/10-install-and-uninstall.feature once. A shaping baseline run passed all eight scenarios in 80.6 seconds and observed 102166 distinct non-directory workspace paths across AfterStep snapshots. Acceptance uses the same counting definition and prints that measured before count and the candidate after count; this is not a claim to count transient files created and deleted inside a step or OS fsevents.
- Addressed: test-only scope and no new command, flag, option, timeout, retry or limit changes apply to all implementation edits. Internal test instrumentation is not a new product option.
- Omitted: no requested behavior. Superseded: full private source copies are no longer the isolation mechanism. No host-load target or paid/live qualification is added.

## Tests
- Remove full per-scenario release copies: independent chapter runner counts workspace file paths and detects full release roots after each step; count must fall below measured baseline and full copies must be zero (regression)
- Keep install and uninstall behavior with real release bytes: all eight existing chapter 10 scenarios must execute and pass exactly once (scenario)
- Isolate corrupted release metadata and preserve upgrade/uninstall and parallel behavior: preserve existing assertions and run the complete non-live suite via sh test/suite.sh before landing, in addition to configured checks; do not put this long gate inside approval acceptance (existing)

## Feasibility
- Baseline targeted chapter run: exit 0, 80.6 seconds; eight scenarios and 91 steps passed; 102166 distinct non-directory workspace paths observed after steps. Count excludes shared suite extraction and includes installed payloads while present, even when later uninstalled. No external protocol or new library assumptions are introduced.
- evidence: {"id":"workspace-observer","kind":"observer","inputs":["features/steps/release_copy_observer.cjs"],"observers":["features/steps/release_copy_observer.cjs"],"checks":[{"name":"good","command":"node features/steps/release_copy_observer.cjs control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/release_copy_observer.cjs control bad","exit":1,"output":"rejected\n"}]}
