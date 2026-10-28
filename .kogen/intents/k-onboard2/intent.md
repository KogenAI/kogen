# Guide the getting-started path without ChatGPT

Slug: k-onboard2
Model: not applicable — documentation and a preset file, no state
Acceptance:
- .kogen/intents/k-onboard2/acceptance.feature
- features/steps/k_onboard2_steps.js

A fresh user with only an Anthropic key follows `docs/getting-started.md` and stops at `kogen init`, which fails with `provider/login: not signed in; run kogen provider login chatgpt` because bare init discovery requires ChatGPT. This Intent changes documentation and one preset only. No code, command, flag, output or configuration key changes; every command and key the guide uses already exists.

## Required edits

1. `docs/getting-started.md` (keep the nine level-2 headings and every existing output block valid for the older K-ONBOARD checks):
   - Step 3 says plainly that the automatic discovery of `kogen init` needs a ChatGPT login (use the literal words `needs a ChatGPT login`), and that with only another provider the reader uses the configuration-first path in step 4 (literal `configuration-first` and `step 4`).
   - Step 4 gets a level-3 subsection `### Without ChatGPT` after the existing step 4 content, with: `kogen provider login anthropic` (or the user's provider); `mkdir -p .kogen`, then creating `.kogen/project.yaml` with the complete worked Go example shown in the guide, adapting its setup, checks and acceptance to the project's real ones. The guide must not tell the reader to `cp <kogen-checkout>/docs/presets/anthropic-only.yaml` (a user who installed a release has no Kogen checkout and the release archive does not ship docs/presets); it only mentions that the same model lines are in `docs/presets/anthropic-only.yaml` in the Kogen repository for reference (the literal `anthropic-only.yaml` appears). The worked Go module example is in a ```yaml fence and is a complete configuration: version 1, setup `go mod download`, check `{name: test, run: 'go test ./...'}`, acceptance `run` set to the exact Cucumber command from docs/configuration.md (the one using `KOGEN_CUCUMBER`, `KOGEN_NODE`, `KOGEN_ACCEPTANCE_REPORT`, `KOGEN_ACCEPTANCE_FEATURES`) and `steps_dir: 'features/steps'`, `protect: []`, the anthropic roles of the preset and `shape_workers:` with `enabled: false` as in the preset; then `kogen init` and `kogen doctor` in a ```sh fence. Tell the reader to leave `.kogen/project.yaml` uncommitted: `kogen init` then takes its leftover-configuration path and commits it as `Add Kogen configuration` together with the `.gitignore` entry for `.kogen/local/`. (If it were already committed, init only reports that Kogen is already initialized and does not add that `.gitignore` entry.) Say that `kogen doctor` runs the setup, checks and acceptance runner too, so its `commands` line needs `go` installed and the project's own tests green.
   - Output blocks for the new path use the fence info strings `text without-chatgpt-init` and `text without-chatgpt-doctor` (not `output <id>`, which the older K-ONBOARD validator rejects for unknown ids). The init block holds `Initialized Kogen in <repo>` and `Commit: <commit> Add Kogen configuration`. The doctor block holds `ok git - repository <repo>`, `ok config - .kogen/project.yaml is valid`, `ok models - shape, build, review ready` and `...` (the commands line is left out).
   - Step 2: the `output doctor-outside-repo` excerpt shows the real lines, in this order: `ok install - <version>; node, cucumber and quint run`, the `fail git` line and its fix, the `fail config` line and its fix, `fail models - shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login` with its fix `kogen provider login chatgpt`, and `skip commands - skipped: the configuration is not valid`. The text before it no longer says "two lines" (nor the words `two lines` anywhere in step 2) and explains that outside a repository there is no Git and no configuration, models fail only when not logged in, and commands are skipped.
2. `docs/presets/anthropic-only.yaml`, same format as `docs/presets/opencode-go-only.yaml` (comment header, `version: 1`, empty setup/fix/checks, acceptance run/steps_dir null, `protect: []`, `shape_workers:` `enabled: false`), with exactly these role lines: `  shape: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}`, `  build: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}`, `  review: {provider: anthropic, model: claude-opus-5-5, effort: medium}`.
3. `docs/configuration.md`: add `- [Anthropic only](presets/anthropic-only.yaml): Sonnet 5.5/medium for shape and build, Opus 5.5/medium for review.` to the preset list next to the other presets.

## Decisions
- Document the leave-uncommitted route, because the actual `kogen init` takes the leftover-configuration commit path only for an uncommitted configuration and that path also adds the `.gitignore` entry (source: request)
- Anthropic preset efforts are medium for all roles; models are the official ones from `kogen provider list` (source: request)
- New output excerpts use `text without-chatgpt-*` fences so older docs checks stay valid (source: request)
- The guide has the reader create `.kogen/project.yaml` from the complete example in the guide, not copy from a Kogen checkout, because release installs have no checkout and the archive ships no docs/presets; the preset file is only named as a repository reference (source: request)

## Source comparison
- Step 3 states the ChatGPT requirement and points to step 4: addressed (Required edits 1; scenario 1).
- Step 4 Without ChatGPT subsection with Go example, init and doctor: addressed (Required edits 1; scenarios 1, 2, 4).
- Correction: no `cp <kogen-checkout>/docs/presets/anthropic-only.yaml`; create `.kogen/project.yaml` from the guide's complete Go example, adapting setup/checks/acceptance, mention the preset in the Kogen repository for reference, keep `mkdir -p .kogen`: addressed (Required edits 1 step 4; Decisions). This supersedes the earlier cp instruction. The scripted run writes the guide's yaml fence, so it already checks the example.
- "commit it, then run kogen init": superseded. A committed configuration makes init print `Kogen is already initialized`; the leftover-commit path is taken when the configuration is uncommitted, so the guide says to leave it uncommitted (Decisions). The user outcome (init succeeds, config and models ok in doctor) is unchanged.
- Step 2 real lines and no "two lines": addressed (Required edits 1; scenarios 1, 3).
- anthropic-only preset and configuration.md listing: addressed (Required edits 2, 3; scenario 5).
- Guide output blocks for the new path checked against a scripted run: addressed (scenario 4); the fences use `text` info strings (Decisions).
- No code, command, flag, output or key change; existing checks pass: addressed (scope limited to docs; scenarios use only existing commands).
- The scripted run has no ChatGPT credential and no model call; doctor's commands line is not asserted because it depends on a Go toolchain on the host.

## Tests
- Step 3 states the ChatGPT requirement, step 4 has the Without ChatGPT subsection with the Go example and excerpts, step 2 shows real lines without "two lines": guide content checks (scenario)
- Every kogen command in the new path is a real command with real options: parse each through the installed CLI help path (scenario)
- The step 2 excerpt lines occur in a real doctor run outside a repository: compare with actual output (scenario)
- Following the new steps with only an Anthropic key makes init succeed and doctor report config and models ok, and bare init without ChatGPT still fails: scripted temp-repo run (scenario)
- The preset has the specified roles, parses as version 1 and is listed in configuration.md: preset and doctor checks (scenario)
- Existing docs checks (K-ONBOARD) stay valid: existing tests (existing)

## Feasibility
- evidence: {"id":"guide-observer","kind":"observer","inputs":["features/steps/k_onboard2_steps.js"],"observers":["features/steps/k_onboard2_steps.js"],"checks":[{"name":"good","command":"node features/steps/k_onboard2_steps.js --control good","exit":0,"output":"accepted\n"},{"name":"bad","command":"node features/steps/k_onboard2_steps.js --control bad","exit":1,"output":"rejected\n"}]}
