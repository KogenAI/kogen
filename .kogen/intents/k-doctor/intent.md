# Add kogen doctor readiness command

Slug: k-doctor
Model: not applicable — a read-only diagnostic command and a summary line; no state machine.
Acceptance:
- .kogen/intents/k-doctor/acceptance.feature
- features/steps/k_doctor_steps.js

`kogen doctor [--project <dir>] [--quick] [--json]` reports what is ready for a first feature and how to fix what is not. `kogen init` ends by running the equivalent of `kogen doctor --quick` and printing its summary; init is otherwise unchanged. Doctor makes no model call and no network request beyond what a provider's existing local credential check already does without a request, changes nothing in the checkout, index or HEAD, and adds no timeout, retry or limit (commands run without a time limit, as Build startup does).

## Interface
- `--project` defaults to the current directory's repository. `--quick` skips the `commands` check. `--json` selects the JSON form. Exit 0 when no check is `fail`, 1 otherwise; usage errors keep the CLI's existing exit 2. `doctor` is added to help pages and parsing like other commands.
- Text form: exactly one line per check, in this order: `install`, `git`, `config`, `models`, `commands`. Line: `<status> <check> - <detail>` with status `ok`, `fail` or `skip` and a one-line detail. Each `fail` line is followed by exactly one line `  fix: <exact command or edit>` (several fixes joined with `; `). No other lines are printed by `kogen doctor`.
- JSON form (`--json`): stdout is only a JSON array, in the same order, of objects with exactly the keys `check`, `status`, `detail`, `fix`; `fix` is the same text as the `fix:` line for a `fail` and `""` otherwise. Same exit status as text.

## Checks
- `install`: kogen version, and Kogen's lib present and runnable: the Node path from `node-path` (`node --version` runs), bundled Cucumber and Quint. Fix: reinstall Kogen.
- `git`: inside a Git repository; `user.name` and `user.email` set (the K21 rule, global or repository). Fix text as in K21's `git_identity_missing` message: `run git config user.name "<name>" and git config user.email "<email>" (global or repository)`.
- `config`: `.kogen/project.yaml` present and valid using the existing parser/validation. Its errors, with line numbers (for example `line 11: models.shape.effort "ultra" is not supported; accepted: ...`), form the detail; the fix names `.kogen/project.yaml` and the line to edit. Absent file: fail with fix `kogen init`.
- `models`: runs even when `config` failed, using the roles readable from the file (omitted keys defaulting as the configuration guide says). For each role (shape, build, review, and enabled shape workers): the route is known; for a provider route a stored login exists (the facts `kogen provider list` reports, offline) else fix `kogen provider login <provider>` (listed once per provider); for `executor: claude-code`: a `claude` binary on PATH (else fail, fix `npm install -g @anthropic-ai/claude-code`), its version at least `claudecode.MinVersion` (2.1.295; the detail names the found and the minimum version), and either a stored token (fix `kogen provider login claude-code`) or `claude auth status` reporting a subscription sign-in. An unsupported effort is reported by `config`; `models` must not hide it.
- `commands`: skipped with `--quick`, and skipped (detail names why) when the config is invalid. Otherwise runs the configured setup commands and every configured check once on the committed tree in a scratch copy, exactly as Build startup would (same setup and environment; never in the checkout), without any time limit, and reports each with its exit status and duration, e.g. `broken status=7 in 12ms`. A failing check makes the line `fail` and its detail says Build would record it as a baseline failure and could not land until it passes (the fix says to make the check pass or repair it in a Build; it does not recommend removing the check); a failing setup command likewise fails. Acceptance runner: configured `run` null is skipped; otherwise reachability is checked by running Kogen's bundled Cucumber `--version` under the same environment, `fail` when it does not run.
- The checkout (tracked and untracked files, modes, index bytes, HEAD) is identical before and after doctor, including when a check writes files.

## Decisions
- One line per check, the fix on a following `  fix:` line (source: request)
- An unsupported effort is reported by the `config` check, which carries the parser's line numbers; `models` still runs so a missing login is reported in the same pass (source: request)
- The Claude Code install command is `npm install -g @anthropic-ai/claude-code` (source: request)

## Source comparison
- `kogen doctor [--project] [--json]`, exit 0/1, one line per check with ok/fail/skip, fix for each fail: addressed (Interface; scenarios 1-3, 5).
- `--json` array of {check,status,detail,fix}: addressed (scenario 5 compares it with the text).
- Check order and contents install/git/config/models/commands: addressed (Checks; scenario 1 order and fails, 3-4 claude, 2 commands). The `install` fail path is not exercised (needs a damaged install).
- `--quick` skips commands: addressed (scenario 2). Acceptance runner reachable: addressed in prose; fixtures have no acceptance runner, so only the skip path is exercised.
- init ends with `doctor --quick` summary: addressed (scenario 7).
- No model call, no checkout/index/HEAD change, no new timeout/retry/limit: addressed (scenario 6 compares checkout identity; scenarios use no provider except init's scripted local fake).
- Stored claude-code token, `claude auth status` sign-in and at-minimum claude: addressed in prose; scenarios cover only missing and too-old claude (Go unit tests cover the rest).
- "All configured checks pass": existing project checks, unchanged.
- Host safety: scenarios use synthetic credentials and only processes they start.

## Tests
- doctor text/JSON output, order, exit codes: scenarios 1 and 5 (scenario)
- git identity, config effort with line number, missing provider login with fix, and the fixed state exiting 0: scenario 1 (scenario)
- failing check reported with status, duration and baseline-failure hint; --quick skips: scenario 2 (scenario)
- claude missing and too old: scenarios 3 and 4 (scenario)
- checkout identity unchanged: scenario 6 (scenario)
- init prints the doctor --quick summary: scenario 7 (scenario)
- claude version comparison, stored-token and auth status decision, per-role route/login checks, install check, acceptance runner check, duration formatting: Go unit tests in the new doctor package with fake binaries and a temp HOME (unit)
- argument parsing of `doctor` (--project, --quick, --json, unknown option exit 2): parse tests in cli/main_test.go (unit)

## Feasibility
- none
