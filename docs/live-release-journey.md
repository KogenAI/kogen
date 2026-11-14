# Live release journey on a heavy project

`test/live/real-use.sh` runs Kogen from its release archive on a real project: install, sign in, init, Shape, approve, Build, the project's own checks without Kogen, independent Review, one commit, uninstall.
The `studio` project adds a dependency-heavy Elixir/Phoenix journey to the existing `example` (Tiny Tasks) and `kogen` journeys, which behave as before.
This is a committed harness only. A run of it is one observation: it is not qualification, a release or proof of build reliability.
The umbrella issue 1bb47857-fa97-4354-99df-ebcea0db29ae stays open until a live run is recorded.
The model-free Delivery Studio replay is separate and is not part of this journey.

## Run it

```sh
sh test/live/real-use.sh studio <archive-url>
```

`<archive-url>` is the release archive for this platform (`https://` or `file://`). The run needs:

- Authenticated Git access to KogenAI/studio. `KOGEN_STUDIO_URL` names the source and defaults to `git@github.com:KogenAI/studio.git`.
- The Erlang and Elixir toolchain on `PATH` (`mix`), and network access for Hex.
- A signed-in route, as in the header of `test/live/real-use.sh`: a Claude Code token through `KOGEN_LIVE_CREDENTIALS`, or the ChatGPT browser login.
- The spend guard: one run is a full Shape, Build and Review of a dependency-heavy project on real models. Start it on purpose, once, and do not wrap it in a retry loop.

`KOGEN_LIVE_RUN_DIR` picks the run folder; the default is a fresh temporary one. Everything of the run lives there: the Studio clone (`studio-origin`), the run's HOME with its Hex and Rebar archives, and the Studio data directory.
`STUDIO_TEST_DATABASE_URL` and `STUDIO_TEST_PG_BIN`, when Studio's tests use them, come from your environment and must name a disposable test database, never production.

## The frozen task

The source is checked out at the frozen KogenAI/studio commit `b93ff1d6c0748d74ee410615ed07cafbb7de1f07`.
`KOGEN_STUDIO_REVISION` replaces it only when `KOGEN_STUDIO_CORPUS_UPDATE` names a separately recorded corpus update; otherwise `test/live/projects/studio.sh` stops with `studio: revision override needs KOGEN_STUDIO_CORPUS_UPDATE`.
The task is the reliability probe `Studio.KogenReleaseProbe.normalize_label/1` in `lib/studio/kogen_release_probe.ex`: a binary is trimmed and downcased, a nonempty result is `{:ok, normalized}`, a whitespace-only binary is `{:error, :empty}`, and every nonbinary is `{:error, :invalid_type}`. It is not a production feature.
After the Build, `verify_without_kogen` runs Studio's own `mix format --check-formatted` and `mix test`, then an independent `mix run` assertion of the six examples above.

## Stages and the result

The run records each stage (`shape approve build verify review commit`) in `journey.tsv` in the run folder as `<utc>`, name, `ok`, `failed` or `skipped`, and elapsed seconds.
At the end `journey_conclude` requires every stage to be `ok`, a new final commit, the line `Kogen-Intent: <slug>` in its body and the task's file in HEAD.
It prints `journey: complete <sha>` and writes `journey-result.txt` with the stage table, the archive sha256, platform, route, source revision, elapsed time and final commit.
Any other end prints the first cause: `journey: stage <name> missing|skipped|failed`, `journey: no new final commit`, `journey: final commit lacks Kogen-Intent: <slug>` or `journey: final commit lacks <file>`.

## Failure and blocked

The first failure stops the run and its cause stays in `transcript.txt`; the harness never retries a stage or a run.
If the source cannot be read, the frozen commit is absent or HEAD differs from it, the run prints `studio: blocked: <reason>` and stops before anything else. A blocked run is not green and is not skipped.
`test/live/check-journey.sh` holds the deterministic negative tests of the conclusion rules and the Studio settings (no model, no network). `test/suite.sh` runs it with `test/live/check-verify.sh`.

## Smallest journey matrix

Studio is expensive, so it is not multiplied over routes. It runs once, on the external `claude-code` route, the route the heavy corpus uses.
The native `chatgpt` route stays covered by the existing `example` journey.
`journey-result.txt` records the route that ran. Any route or project that was not executed is reported as not run, never as passed.
