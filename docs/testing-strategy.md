# Testing strategy

`sh test/suite.sh` runs the complete deterministic suite: unit/property and installed-release integration checks, uncached Go race tests, every non-live Gherkin scenario, specification checks and the real-use script’s own failure-propagation check. Real provider journeys remain the separate release checks below.

The normal full deterministic run takes **a couple of minutes**. Keep the suite simple; this is a practical speed goal, not a reason to remove checks or add elaborate timing machinery. Measure end-to-end wall time with locked tools/dependencies installed, including a build from current source; report any separate dependency/fixture preparation. A selected subset, skipped scenario, cached test result or successful retry is not a full passing run. Reuse a fresh release archive within a run and keep test workspaces independent.

## The standard for every test

A test earns its place when it catches a concrete mistake and can be maintained without constraining legitimate implementation changes. So:

- assert outcomes and rules, not structure: a test must survive renames, moved helpers and refactors that keep the behavior;
- choose tests by risk, not by module count;
- keep real local dependencies (temp files, disposable git repos, real processes); add no abstraction only to make something mockable;
- when behavior changes or is removed, update or delete its tests in the same change.

## Layers

| Layer | What it gives evidence for | Tools |
| --- | --- | --- |
| Unit / property | Kogen's own rules where a mistake is easy and costly (list below) | ExUnit, Go `testing`; StreamData only where a concrete property exists |
| Integration | core behavior against real git in temp repos, real hooks, real OS processes, the fake provider over HTTP | ExUnit `@tag :integration` |
| Scenarios | the spec's contract through the installed program: every non-`@live` scenario in `spec/features` | Cucumber, `test/acceptance/` |
| Spec | Gherkin parse, clause coverage, Quint invariants and their refuted false variants | `spec/check.sh` |
| Real use | the full live journey: install, login, shape, build, review, commit | `test/live/real-use.sh` on the example app; real projects outside the repository as an external check |

**Preserve contract coverage.** Installed scenarios cover interrupts, hooks, environment and packaging. A scenario is removed only when it gives the same evidence as another one. A unit test never repeats a scenario's example; it covers the cases a scenario cannot reach cheaply.

One explicit duration exception keeps the five-minute probe policy test fast. Its test-only driver starts the unmodified installed core, verifies that its real execution request specifies 300,000 ms, then passes that request with a 200 ms deadline to the real Go executor. The executor supplies its genuine timeout result to the core; the test checks process cleanup, shaping continuation and scratch cleanup. This is composed core/executor coverage, not evidence that five actual minutes elapsed through the unmodified installed CLI. The production timeout, clock and executable are unchanged; no slow case is silently excluded.

**Quint** stays a spec check. The key guarantees it states (no commit without an approved green pass of the same contents; an interrupt leaves no new commit; one Build per repository) each have an implementation test, listed by `node spec/tools/check.mjs --trace`. There is no model-to-test framework.

## Where the unit and integration tests are

1. **Approval hash** (AUT-2, VER-1): any change, addition, removal or rename in the baseline changes the hash, independent of order; `protect` patterns select the right files. This is a StreamData property.
2. **Scenario-result accounting** (VER-4): from Cucumber reports, a scenario counts as passed only when it finished with every step reported. Cases: missing, duplicate, unexpected, retried, truncated report, garbage line, exit ≠ 0. This is a StreamData property over generated reports.
3. **Kogen's use of its parsers**: how `.kogen/project.yaml` is interpreted (commands, checks, models, protect), and that invalid input is reported with its file and line. This tests Kogen's interpretation, not the parsing technique.
4. **Review and repair loop**: invalid verdicts (one retry, then `review_invalid`); `changes` leads to a repair and a new pass; files that change during checks keep the pass from being green.
5. **Commit and hooks** (GIT-4..8): a hook that rejects leaves the edits; a hook that edits files gets the commit undone; the user's index is restored on every outcome that does not land; signing is a scenario with a test SSH key (`07-committing.feature`).
6. **Credentials**: a stale lock is removed and a live one waits. Two commands refreshing at once rotate the token once: a scenario (`08-chatgpt.feature`).
7. **Protocol bytes** (CLI-9): non-ASCII and invalid-UTF-8 command output survives the bridge under both a UTF-8 and an empty locale.
8. **CLI** (Go, `go test -race`): the command tree, grammar and help pages; the start handshake, a core crash, signal-to-exit-code mapping (130/143/129), an interrupt during a silent core startup; process groups stopped TERM, then KILL; output capture; the probe timeout.
9. **Model-check feedback** (VER-5): a real Quint error keeps the message Quint prints first and the summary it prints last.

## Test doubles

- **External HTTP services are scripted test fixtures**, covering the model provider and, for the missing-Node installer scenario, a local Node-distribution fixture backed by the actual pinned Node installation. The installer still runs real curl and tar, installs real files and executes the installed Node binary. The catalog includes a newer non-LTS release so choosing the first row instead of the LTS row fails. This checks the installer deterministically; online nodejs.org availability is not a local behavior assertion. The probe-deadline test driver composes real core/executor behavior as explicitly described above; it is not a fake process or timeout result. (The Go tests also use a scripted stand-in core: it is the protocol peer that lets the bridge be tested alone, while the installed-release scenarios give the Go-to-Elixir evidence.) The provider fake is scripted: named scripts that react to the request, as `test/acceptance/support/fake-servers.js` does today. No recorded conversations, because recordings break whenever a prompt changes. ExUnit points `KOGEN_PROVIDER_URL`/`KOGEN_AUTH_URL` at a small local fake.
- **Never faked**: git (temp repos with an isolated `HOME` and `GIT_CONFIG_GLOBAL`, so the host's hooks and signing stay out), files (temp dirs, including the macOS `/var` symlink), processes and signals, Cucumber, Quint, the installed release.
- **Time** is not injected: expiry is set through stored timestamps, and tests assert formats, not clock values. The one probe deadline contraction described above occurs explicitly at the test protocol boundary after asserting the production five-minute request; it never fabricates the timeout result.

## The example app

There is one example app, `examples/tiny_tasks/` (a task list driven by `mix todo.*` commands): a small, understandable existing implementation in plain Elixir, with no database and no Hex deps. It comes with one meaningful feature request (completing a task, listing open tasks) that leaves one UI/UX choice open (REL-1 step 4).

- **Reset each run.** `test/live/projects/example.sh` copies it into the run folder and makes a fixed baseline commit (known identity and date). Nothing carries over between runs.
- **Deterministic apart from the live journey.** There is no network, service or uncontrolled timing in the app or its checks. Toolchain and Cucumber are pinned; once the npm packages are installed (or cached), the app and its checks run offline. Only the Kogen journey itself talks to ChatGPT.
- **Checks judge outcomes.** The app's own tests plus an independent feature check accept any correct implementation, whatever the choices in naming, structure or the open UI/UX choice. They also reject plausible wrong ones. The generated code is never compared with a reference.
- **Qualification is of the checks, not of model runs.** Before the app is used, show that the baseline passes reliably from a clean environment on both platforms, and that deliberately wrong implementations fail the feature checks. `examples/tiny_tasks-qualification/qualify.sh` does this: 5 baseline runs, three wrong patches (completion drops the other tasks, `--open` selects done tasks, completion reverses the order) rejected, a reference patch accepted. Repeat this when a check or the toolchain changes. N passed live runs prove nothing about the next run and are not a gate.

## Live runs: results and failures

Every attempt is kept: its run folder, its transcript and its result. A retry never erases the first result. Every failure is investigated and classified as one of:

- **Kogen defect**: Kogen broke a clause, crashed, hung, leaked a token, or committed something it should not have. **Kogen accepting an incorrect result is a product defect immediately**, even if a rerun passes. Fix the cause and add a test at the lowest layer that shows it.
- **Provider or access failure**: rate limit, expired login, network. Recorded, then rerun.
- **Example defect**: the example's checks failed on the unchanged tree, or accepted or rejected something they should not have. Fix the example and re-qualify its checks.
- **Unsuccessful generated implementation**: Kogen behaved as specified and reported that it could not finish. Read the run; if the instructions or feedback Kogen gave were the reason, it is a Kogen defect.

Kogen's Build has no limits. If the harness abandons a run (for example, the host has to be freed), it reports **INCOMPLETE** with the reason, never a pass or an unexplained failure.

## When to run what

- While editing: the focused tests for the code being changed.
- **Routine gate, before an ordinary commit:** the unit tests (`mix test test/kogen`), the integration tests and scenarios of the behavior the change touches (the feature files whose clauses it changes, or that run the changed code), `spec/check.sh` when `spec/` changed, and `go test -race ./...` when `cli/` changed. A change to a default value or to documentation needs only what shows that value or text.
- **Release gate:** `sh test/suite.sh` (every layer, every non-`@live` scenario) on macOS and Linux, then the live runs. Also run the full suite on both platforms after changes to packaging, processes, signals, locale or paths. A trial build for someone to try may ship after the routine gate; say what it has not been through.
- Live runs (the example app, then the external projects): before a release, or when the provider route, packaging or the Build journey changes.
- Parallel scenarios retain independent homes, repos and ports. Cucumber’s existing scheduling support keeps login scenarios mutually exclusive around port 1455; other independent scenarios may run concurrently. Measure complete results and wall time, including setup, and preserve each failure.

## Changes Kogen builds (each Intent)

Every changed behavior gets appropriate evidence. Often updating an existing test or scenario is enough. Wiring may need only a scenario. New rules with costly edge cases get unit or integration tests by the standard above. Obsolete tests go in the same change. There is no coverage % target; `mix test --cover` is information only. The rules for choosing tests, and for specifying a change so it can be tested, are `docs/testing-rules.md`; the shaper, the builder and the reviewer each get its text (SET-6).
