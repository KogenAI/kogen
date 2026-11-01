# Fold kogen doctor into init and command errors

Slug: k-doctor-fold
Model: not applicable — removes a read-only diagnostic command and rewords output and error text; no state machine changes.
Acceptance:
- .kogen/intents/k-doctor-fold/acceptance.feature
- features/steps/k_doctor_fold_steps.js

`kogen doctor [--project <dir>] [--quick] [--json]` (added in b91196b, 28 Oct) is outside Kogen's agreed CLI, which must not be extended (Studio decision dec-61a5260d6b2445cc; spec/prose/09-cli-and-process.md CLI-1 never listed it). This fix removes the command and folds what it reported into existing output and errors. No command, flag or option is added; every remaining command, flag and output stays as the CLI chapter (spec/prose/09-cli-and-process.md and spec/features/09-cli-and-process.feature) specifies, except the removed `doctor` help line.

## Removed
- The `doctor` command: its parse entry (`leaves["doctor"]`, the `case "init", "doctor", ...` branch in `cli/main.go`), its `--project`/`--quick`/`--json` handling for doctor (the `invocation.quick` field and the `quick` boolean-option branch go; `json` stays for `provider list`), its dispatch in `cli/native.go`, `runDoctor` in `cli/doctor.go`, and the top help line `  doctor     Report what is ready for a first feature and how to fix the rest`.
- `kogen doctor` (any arguments) is then an ordinary unknown command (CLI-2): stdout `kogen: unknown command 'doctor'`, an empty line and the top page; exit 2.
- Code that only the command used: the `commands` check (setup, checks and acceptance-runner run in a scratch copy), the JSON form, the `Quick` input and `FormatDuration`/`Failed` if nothing else uses them, with their unit tests. The remaining readiness checks (install, git, config, models, including the Claude Code checks) stay for init; they may stay in `cli/doctor` or move/rename (implementation choice), but no user-facing text refers to a doctor command.

## Init reports readiness in its own output
After every successful `kogen init` (exit 0: first configuration, empty repository, leftover configuration, already initialized), init's stdout ends with its readiness lines, exactly as before minus the commands line: in order `install`, `git`, `config`, `models`, each `<ok|fail> <check> - <detail>` with the same details as today, and after each `fail` exactly one line `  fix: <fix>` (fixes joined with `; `). The former last line `skip commands - skipped with --quick` is no longer printed (it named a flag that no longer exists; init's own `Setup:`, `Checks:`, `Left out:` and `Acceptance:` lines already report the project's commands). A failing readiness line does not change init's exit 0. They make no model call and change nothing. Example, a fresh project with a login and no detected commands:

```
Initialized Kogen in <repo>
Setup: none
Checks: none found
Acceptance: Cucumber bridge added in features/steps
Commit: <sha8> Add Kogen configuration
Next: add the project's checks to commands.checks in .kogen/project.yaml
ok install - <kogen version line>; node, cucumber and quint run
ok git - repository <repo>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
```

## Each command that cannot proceed names what is missing and the fix
Already true and kept unchanged: damaged install (`environment/installation_damaged: ...; reinstall Kogen`), outside a repository (`environment/not_a_git_repo: <path>; run git init first`), missing configuration (`environment/not_initialized: <root> has no .kogen/project.yaml; run kogen init`, exit 3), invalid configuration (`environment/project_config_invalid` with `  line <n>: <message>` lines), old configuration, missing model login (`provider/login: not signed in; run kogen provider login <provider>`, exit 4), Build's own identity refusal, and Build's baseline-failure reporting for failing checks.

Changed so the message says exactly how to fix it, as doctor's fix did:
- `kogen init` without a Git identity (`git.RequireIdentity`, exit 3 unchanged, still writing nothing): `environment/git_identity_missing: no Git user.name and user.email; run git config user.name "<name>" and git config user.email "<email>" (global or repository)`.
- Claude Code executor (`cli/executor/claudecode/claudecode.go`, reasons unchanged):
  - executable not found: `the Claude Code executable (<base name>) was not found; install it with npm install -g @anthropic-ai/claude-code, then sign in with `claude auth login` or save a token with kogen provider login claude-code`
  - too old: `Claude Code <version> is older than the qualified minimum 2.1.295; update it with npm install -g @anthropic-ai/claude-code` (the minimum is `claudecode.MinVersion`)
  - not signed in: `Claude Code is not signed in; run `claude auth login` with your subscription, or save a token from claude setup-token with kogen provider login claude-code`

## Documentation and specification
- README.md: replace the doctor sentence with one saying `kogen init` ends with readiness lines (install, Git, configuration, model logins) with the exact fix under each failure, and that a command that cannot proceed names what is missing and how to fix it in its error. Keep the `kogen help` / `kogen uninstall` sentence.
- docs/getting-started.md: no doctor. Step 2 explains that readiness comes from init's readiness lines (step 4) and from each command's own error, naming the errors above with their fixes; the init excerpt ends with the four readiness lines; the `doctor-*` excerpts, "Run doctor again" and the doctor run in "Without ChatGPT" go (that section runs `kogen init` only); the fact that a check failing on the unchanged tree becomes a Build baseline failure that must be repaired before landing is kept.
- docs/configuration.md line ~607: "the lenient view used by init's readiness lines".
- spec/prose/01-project-setup.md: SET-2's sentence about `doctor --quick` becomes the readiness-lines rule above; SET-5's message becomes the new identity message.
- spec/features/01-project-setup.feature: drop the four `skip commands - skipped with --quick` lines (scenarios at lines ~9, 41, 67, 155; the rest of their exact stdout, aligned on 1 Nov by K-ACCEPTANCE-GREEN-CLI, stays) and update the SET-5 expected stdout.
- spec/prose/09-cli-and-process.md (CLI-3 top page) and spec/features/09-cli-and-process.feature (four top-page blocks), test/acceptance/support/handlers.js `topHelp`: drop the doctor line.
- None of README.md, docs/getting-started.md, docs/configuration.md, spec/prose/01-project-setup.md, spec/prose/09-cli-and-process.md, spec/features/01-project-setup.feature, spec/features/09-cli-and-process.feature or test/acceptance/support/handlers.js contains the word "doctor" (no removal note either).
- Historical Intent packages under `.kogen/intents/` (k-doctor, k-onboard, k-onboard2, k21b-env-identity, ...) and their step files under `features/steps/` are records of past Builds and stay unchanged.

## Decisions
- Init's readiness output keeps the install, git, config and models lines with today's wording and drops the `skip commands - skipped with --quick` line, which named a removed flag and carried no readiness fact (source: request)
- `kogen doctor` gets the CLI's ordinary unknown-command usage error; no alias or deprecation message (source: request)

## Source comparison
- Remove the `doctor` command, its flags and help entry: addressed (Removed; scenarios 1-2; parse unit tests).
- Remove its README line: addressed (Documentation; scenario 8).
- Update specification prose and scenarios describing it, including init's expected output aligned by K-ACCEPTANCE-GREEN-CLI: addressed (Documentation; scenario 8 checks the files no longer mention doctor or `skipped with --quick`). K-ACCEPTANCE-GREEN-CLI's "retain init's quick-doctor output" is superseded by the 1 Nov ruling.
- Keep every command, flag and output to the agreed CLI (dec-61a5260d6b2445cc, chapter 09); add no command, flag or option: addressed (Removed; scenario 2 pins the exact top page).
- Install, repository, configuration, model logins and commands stay available without a separate command: init readiness lines (scenarios 3-4), existing errors (scenarios 5-6, kept), init identity error made exact (scenario 7), Claude Code errors made exact (unit tests). Commands: init's own Checks/Left out lines and Build baseline reporting, unchanged; the scratch commands run that only `kogen doctor` performed is removed.
- `kogen init` on a fresh project reports the same readiness facts as before: addressed (scenarios 3 and 4, exact stdout with install, git, config and models, and the models failure with its fix).
- A command without a model login, and one without configuration, fails naming the fix: addressed (scenarios 5 and 6, `kogen intent shape`); these pass already and guard the existing behaviour.
- Acceptance against the installed release: the steps package and install the release from this tree (go_driver_support.js), as other installed scenarios do.
- Configured checks pass: Go tests, spec check and the configured cucumber chapter; updated tests listed below.
- No acceptance depends on Build-invented test names.

## Tests
- `kogen doctor` (with or without its old flags) is an unknown command with the top-page usage error, exit 2: acceptance scenario 1 (scenario); parse_test.go doctor cases replaced by an unknown-command case (unit)
- help pages no longer list doctor: acceptance scenario 2 (scenario); parse_test.go top page and spec/features/09 top-page blocks updated (existing)
- init ends with the install/git/config/models readiness lines and no commands line, exit 0 even when models fails: acceptance scenarios 3-4 (scenario); spec/features/01 init stdout updated (existing)
- missing model login and missing configuration name their fix: acceptance scenarios 5-6 (regression)
- init without Git identity names the exact git config commands: acceptance scenario 7 (regression); cli/git/git_test.go and cli/shape/init_test.go expectations and spec/features/01 SET-5 updated (unit)
- Claude Code missing, too old and not signed in name their fix: claudecode package unit tests asserting the three messages (unit)
- removed commands check, JSON form and duration formatting: their tests in cli/doctor/doctor_test.go deleted; install/git/config/models/claude tests kept (unit)
- README, guides and specification no longer describe doctor: acceptance scenario 8 (scenario)

## Feasibility
- none
- Observed on the installed 1dd4335c release (this session's own probes in /tmp, not Kogen probes): an unknown command prints `kogen: unknown command '<x>'`, an empty line and the top page, exit 2; `kogen intent shape` without `.kogen/project.yaml` prints `environment/not_initialized: <root> has no .kogen/project.yaml; run kogen init` (exit 3); with a committed configuration and no login it prints `provider/login: not signed in; run kogen provider login chatgpt` (exit 4); init's stdout today ends with the five doctor lines shown above plus `skip commands - skipped with --quick`.
- The submitted feature dry-runs with no undefined or ambiguous steps, and against the current release 6 of 8 scenarios fail for the missing fold (1, 2, 3, 4, 7, 8) while 5 and 6 pass.
