# Add a getting-started guide for real projects

Slug: k-onboard
Model: not applicable — documentation and two fix texts, no state
Acceptance:
- .kogen/intents/k-onboard/acceptance.feature
- features/steps/k_onboard_steps.js

Add `docs/getting-started.md`, a guide for a developer with an existing Git repository, from install to the first landed feature. Point the README "Getting started" at it, and change two `kogen doctor` fix texts. No command, flag or other output changes; other docs change only by links.

## Guide: `docs/getting-started.md`

Level-2 headings, exactly these nine in this order (each heading text starts with the given words; more words may follow):

1. `## 1. Install`: `install-kogen.sh` from a release (checksum verified) or `packaging/install.sh` from a source build; `kogen version`.
2. `## 2. Check`: `kogen doctor`; what each check (install, git, config, models, commands) means and the fix for each typical `fail` (git identity, provider login, invalid config, a project check failing on the unchanged tree). It says to run doctor inside the project repository, not from the home directory (use the words `home directory`), and explains the two lines Almir saw from the home directory: `fail git - … is not inside a Git repository` with the fix `run this inside your project's repository (cd <repo>), or git init to start a new one`, and `fail config - … missing` with the fix `in your project, run kogen init`, quoting both fix texts exactly.
3. `## 3. Log in`: `kogen provider login <provider>` for the chosen route (ChatGPT subscription, Claude Code token, Anthropic API key, others) and `kogen provider list`.
4. `## 4. Initialise the project`: `kogen init` (what it discovers, the `.kogen/project.yaml` it commits, how to adjust models and checks), then `kogen doctor` again.
5. `## 5. Shape`: a short request file kept outside the repository; `kogen intent shape <slug> <file>`; answering questions (rerun with an answers file of `<n>: <letter>` lines); what the Intent files are.
6. `## 6. Revise`: `kogen intent refine <slug> <sha256> <file>` (the sha256 comes from `kogen intent approve <slug>`) and when to use it instead of editing files.
7. `## 7. Approve`: `kogen intent approve <slug>` shows the card; approve with the printed hash; what the card's sections mean.
8. `## 8. Build`: `kogen intent build <slug>`: rounds, verification, the independent review, the single commit; how to read the result lines; what `build_blocked`, `kogen intent recover` and `kogen intent resume` mean and when to use each.
9. `## 9. Where records live`: `.kogen/local/…` and `kogen uninstall`.

It also names `install-kogen.sh`, `packaging/install.sh`, `build_blocked` and `.kogen/local/` literally.

Conventions the acceptance checks enforce:
- Only existing commands and flags appear. Every line in a fenced block that starts with `kogen ` (or follows a `| ` pipe, as in `printf '1: a\n' | kogen intent shape <slug> -`), and every inline code span that starts with `kogen `, must parse against the CLI. Keep `#` comments after commands, avoid brackets such as `[--project <dir>]` and never write `kogen` + a non-command word inside backticks (use plain prose or a different quoting). The guide shows at least: version, doctor, provider login, provider list, init, intent shape, intent refine, intent approve, intent build, intent recover, intent resume, uninstall.
- Expected output is shown in a fenced block whose info string is `output <step-id>`, immediately after the fenced block holding that step's command. Step ids and the command each follows: `version` (`kogen version`), `doctor-outside-repo` (`kogen doctor` run from the home directory), `doctor-before-init` (`kogen doctor` in the repository before init, with no Git identity, no login and no configuration), `provider-list` (`kogen provider list` after a ChatGPT login), `init` (`kogen init`), `doctor-after-init` (`kogen doctor`), `shape-questions` (`kogen intent shape <slug> <request-file>` that ends with questions), `shape-ready` (`kogen intent shape <slug> <answers-file>`), `refine` (`kogen intent refine …`), `approve-card` (`kogen intent approve <slug>`), `approve` (`kogen intent approve <slug> <sha256>`), `build` (`kogen intent build <slug>`). Every id must have at least one excerpt block. Each non-blank line of an excerpt must equal (after trimming) some line of the actual output of a scripted run of that step (fake provider, temporary repository with a slug `greeting`, synthetic credentials). A line `...` is an elision and is skipped. A `<name>` placeholder (a `<`, a letter, then up to the next `>`) matches any text, for hashes, ids, paths and durations. Build the excerpts from the real run (the scripted journey is in `features/steps/k_onboard_steps.js`), not from imagination.

## README

In the README "Getting started" section add a link to `docs/getting-started.md` and keep the existing build-from-source paragraph short. No other README change.

## Doctor fix texts (output text only)

In `cli/doctor/doctor.go`: outside a Git repository the `git` line's fix is `run this inside your project's repository (cd <repo>), or git init to start a new one` (was `git init`); when `.kogen/project.yaml` is missing the `config` fix is `in your project, run kogen init` (was `kogen init`). Detail text, statuses, exit codes, JSON shape and every other doctor fix are unchanged. Update the doctor tests that quote these fixes (cli/doctor/doctor_test.go) and any spec text that quotes them (a search of spec/ finds no quotation of the old doctor fixes, so no spec edit is expected; do not edit unrelated spec text).

## Decisions
- The guide uses only existing commands and flags; the CLI is unchanged. (source: request)
- Doctor output changes only in the two named fix texts. (source: request)
- The guide tells readers to run `kogen doctor` inside the project repository and explains the two home-directory lines. (source: request)
- Excerpts are verified by the fenced-block convention above because the request requires every output excerpt to be checked against a scripted run. (source: request)

## Source comparison
- Guide at docs/getting-started.md with nine ordered steps, exact commands and output excerpts: addressed (Guide section; scenarios 1-3).
- Commands parse against the CLI table; no other kogen commands: addressed by running each guide command through the real `kogen <tokens> --help` path, which validates command, subcommand and options and executes nothing (scenario 2).
- Output excerpts checked against a real scripted run with the fake provider in a temp repo, placeholders allowed: addressed (scenario 3; twelve step ids).
- README links to the guide, build-from-source paragraph kept short: addressed (scenario 1; README section).
- Doctor git and config fix texts: addressed (scenarios 4-5; Doctor section). Spec text quoting them: no quotation exists in spec/, so no spec edit is required; unit tests in cli/doctor/doctor_test.go are updated.
- All configured checks pass: the Build's normal verification.
- Field note (home-directory doctor lines): addressed in step 2 content, checked by required texts.
- Host safety (synthetic tokens, temp dirs, no real provider, no process stopping by name): addressed; the journey uses a local fake provider and temp directories, and the command parse check executes nothing.
- Login output is not shown with an excerpt (browser or device flow cannot be scripted); `provider-list` after a seeded synthetic login stands in. This is a deliberate scope choice.

## Tests
- Guide has nine ordered headings, required literals, README link: scenario 1 (scenario)
- Every guide command parses against the CLI command table and covers all steps: scenario 2 (scenario)
- Every output excerpt occurs in a real scripted run: scenario 3 (scenario)
- Doctor outside a Git repository prints the new git and config fix texts: scenario 4 (scenario)
- Doctor in a repository without project configuration prints the new config fix text: scenario 5 (scenario)
- The two changed doctor fix texts: update cli/doctor/doctor_test.go to assert the new texts (unit)
- Every other doctor output, command and flag stays unchanged: existing doctor tests and K-DOCTOR scenarios (existing)

## Feasibility
- evidence: {"id":"guide-observer","kind":"observer","inputs":["features/steps/k_onboard_steps.js"],"observers":["features/steps/k_onboard_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_onboard_steps.js --control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_onboard_steps.js --control bad","exit":1,"output":"rejected\n"}]}
