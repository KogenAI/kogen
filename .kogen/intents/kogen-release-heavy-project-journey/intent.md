# Add heavy-project live release journey

Slug: kogen-release-heavy-project-journey
Model: not applicable — shell harness and settings with no meaningful state machine
Acceptance:
- .kogen/intents/kogen-release-heavy-project-journey/acceptance.feature
- features/steps/kogen-release-heavy-project-journey__steps.js

Extend the existing `test/live/real-use.sh` and its project settings mechanism with a `studio` project: a real dependency-heavy Elixir/Phoenix journey (Shape, approval of exactly the generated package, Build, final verification, independent Review, commit). The existing `example` and `kogen` journeys are retained unchanged in behavior. No parallel harness, no cache manager, no Studio code vendored into Kogen. The model-free Delivery Studio replay stays separate. This Intent adds a committed harness only; it is not qualification, a release or proof of build reliability, and it does not close the umbrella issue 1bb47857-fa97-4354-99df-ebcea0db29ae. Delivery-owned release registration and other component repositories are out of scope.

## Interfaces

`test/live/projects/studio.sh` (sourced by real-use.sh like the other settings; sourcing performs no network access):
- `STUDIO_REVISION=b93ff1d6c0748d74ee410615ed07cafbb7de1f07`, the frozen KogenAI/studio commit. `KOGEN_STUDIO_REVISION` may override it only when `KOGEN_STUDIO_CORPUS_UPDATE` is also set to a non-empty reference of a separately recorded corpus update; otherwise sourcing fails (nonzero) printing `studio: revision override needs KOGEN_STUDIO_CORPUS_UPDATE`.
- `KOGEN_STUDIO_URL` (default `git@github.com:KogenAI/studio.git`) names the authenticated source.
- `REPO=$KOGEN_LIVE_RUN_DIR/studio-origin`, `SLUG=normalize-label-probe`, `REQUEST` carrying the frozen task: add `Studio.KogenReleaseProbe.normalize_label/1` in `lib/studio/kogen_release_probe.ex`; binary input trimmed and downcased, nonempty gives `{:ok, normalized}`, whitespace-only binary gives `{:error, :empty}`, every nonbinary gives `{:error, :invalid_type}`; project-native tests for mixed case, surrounding whitespace, empty/whitespace input and nonbinary input; a reliability probe, not a production feature.
- `prepare_repo()`: clones `KOGEN_STUDIO_URL` into `REPO` in the isolated run folder and checks out `STUDIO_REVISION`; if the source is unreadable, the commit is absent, or `git rev-parse HEAD` differs from the revision, it prints `studio: blocked: <reason>` and returns nonzero. Never green, never skipped.
- `configure()` and `verify_without_kogen()`: setup/checks keep init's Elixir commands, portable on Mac and Linux, with isolated test data (isolated database/data directories under the run folder, never production), no symlinked caches into the source checkout, no change to Mix invalidation. `verify_without_kogen` runs the project's own `mix format --check-formatted`, `mix test`, and an independent `mix run` assertion of normalize_label/1 for `"  MiXed Case "` → `{:ok, "mixed case"}`, `"   "` → `{:error, :empty}`, `""` → `{:error, :empty}`, `nil`/`42`/`:atom` → `{:error, :invalid_type}`.

`real-use.sh` calls `prepare_repo` (when the settings define it) before cloning `REPO`, and records stages through `test/live/journey.sh` (POSIX sh, sourced after `run_dir`, `say`, `fail` exist):
- `journey_begin` starts the clock.
- `journey_stage <name> <ok|failed|skipped>` appends `<utc>\t<name>\t<status>\t<elapsed seconds>` to `$run_dir/journey.tsv`.
- `journey_conclude <start-commit> <final-file>` requires every stage of `JOURNEY_STAGES` (default `shape approve build verify review commit`) to have a recorded `ok`; otherwise `fail`s with `journey: stage <name> missing|skipped|failed` for the first offending stage. It then requires HEAD differs from `<start-commit>` (`journey: no new final commit`), the commit body to contain the line `Kogen-Intent: $SLUG` (`journey: final commit lacks Kogen-Intent: <slug>`), and `<final-file>` present in HEAD (`journey: final commit lacks <file>`). On success it says `journey: complete <sha>` and writes `$run_dir/journey-result.txt` with stage table, archive sha256, platform, route, source revision, elapsed time and final commit. The first failure's cause stays in the transcript; the script never retries.

`test/live/check-journey.sh` holds focused deterministic negative tests of these (no model, no network) and is run by the suite's live-helper layer in `test/suite.sh`. `docs/live-release-journey.md` documents the exact invocation `sh test/live/real-use.sh studio <archive-url>`, prerequisites (authenticated access to KogenAI/studio, Erlang/Elixir toolchain, a signed-in route, the spend guard), the failure/blocked semantics and the smallest journey matrix: one Studio run on the native `chatgpt` route and one on the external `claude-code` route are not both multiplied over the corpus; the Studio journey runs once on the `claude-code` external route (the route exercised by the heavy corpus) while the native `chatgpt` route stays covered by the existing example journey, and any route not executed is reported as not run, never passed.

## Decisions
- Settings file `test/live/projects/studio.sh` plus a sourced `test/live/journey.sh` extend real-use.sh; no new harness or cache manager (evidence: test/live/real-use.sh; test/live/projects/example.sh; test/live/checked.sh) (source: request)
- Corpus revision is a constant overridable only with a recorded corpus-update reference (source: request)
- Matrix: Studio on claude-code external route once, native route via the existing example journey; unexecuted routes never claimed (assumption: confirm which route the single expensive Studio run uses) (source: request)
- Live execution is not performed by acceptance; the umbrella stays open until a live run is recorded (source: request)

## Source comparison
- Frozen Studio commit, task, no vendoring, isolated clone and data, Mac/Linux compatibility, no cache symlinks: addressed in studio.sh and docs.
- Failure custody, no retries, stage/commit negative tests: addressed in journey.sh and check-journey.sh.
- Component regressions, Delivery release-job work: omitted, owned elsewhere.

## Tests
- Stage and final-commit conclusion rules: journey conclusion scenarios with missing, skipped, failed stages and absent or wrong commits (scenario)
- Pinned revision, override guard, blocked corpus access: studio settings scenarios (scenario)
- Existing deterministic helper tests stay green: check-verify.sh and check-journey.sh (existing)
- Wiring and documentation: scenario reading real-use.sh, suite.sh and docs (scenario)

## Feasibility
- none
