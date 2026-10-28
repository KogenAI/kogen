# Getting started

This guide takes you from nothing installed to your first feature landed in your own Git repository. You need Git, a repository with at least one commit, and a model route you can sign in to. Every output block below is an excerpt of a real run (`...` marks lines left out; `<name>` stands for a hash, id, path or duration that differs on your machine).

## 1. Install

From a release, run `install-kogen.sh`. It downloads the archive for your platform, verifies its checksum and installs into `~/.local` without administrator rights. From a source build (`sh packaging/package.sh`), unpack `dist/kogen-<version>-<platform>.tar.gz` and run `packaging/install.sh` from the unpacked folder (it is named `install.sh` there). If `~/.local/bin` is not on your `PATH`, add it. Then check the program runs:

```sh
kogen version
```

```output version
kogen <version>
```

## 2. Check

Run doctor **inside your project repository**, not from your home directory. It makes no model call and changes nothing:

```sh
kogen doctor
```

It prints one line per check, with the exact fix under each `fail`:

- `install`: the program and its bundled node, cucumber and quint run. Fix: reinstall.
- `git`: you are inside a Git repository and Git has a `user.name` and `user.email`. Fix for a missing identity: run `git config user.name "<name>"` and `git config user.email "<email>"`.
- `config`: `.kogen/project.yaml` exists and is valid. Fix for a missing file: run `kogen init` (step 4). For an invalid file, correct the key doctor names in `.kogen/project.yaml`.
- `models`: every role (shape, build, review) has a stored login for its provider. Fix: `kogen provider login <provider>` (step 3).
- `commands`: the project's checks and the acceptance runner pass on your unchanged tree. If a check fails there, fix the project or remove that check from `commands.checks` in `.kogen/project.yaml`; Kogen cannot build on a tree that is already red.

Run from your home directory, doctor shows what a wrong place looks like: outside a repository there is no Git and no configuration, so `git` and `config` fail; `models` fails only when you are not logged in; and `commands` is skipped because the configuration is not valid:

```sh
cd ~
kogen doctor
```

```output doctor-outside-repo
ok install - <version>; node, cucumber and quint run
fail git - <directory> is not inside a Git repository
  fix: run this inside your project's repository (cd <repo>), or git init to start a new one
fail config - .kogen/project.yaml is missing
  fix: in your project, run kogen init
fail models - shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login
  fix: kogen provider login chatgpt
skip commands - skipped: the configuration is not valid
```

The `git` fix is `run this inside your project's repository (cd <repo>), or git init to start a new one`: change into the repository, or start a new one with `git init`. The `config` fix is `in your project, run kogen init`: the configuration belongs to a project, so do this inside it.

In a new repository with no Git identity, no login and no configuration, the expected failures are these:

```sh
cd <repo>
kogen doctor
```

```output doctor-before-init
fail git - no Git user.name and user.email
  fix: run git config user.name "<name>" and git config user.email "<email>" (global or repository)
fail config - .kogen/project.yaml is missing
  fix: in your project, run kogen init
fail models - shape: chatgpt has no stored login; build: chatgpt has no stored login; review: chatgpt has no stored login
  fix: kogen provider login chatgpt
skip commands - skipped: the configuration is not valid
```

## 3. Log in

Sign in for the route you chose. Each command stores the login privately under `~/.kogen`:

```sh
kogen provider login chatgpt        # ChatGPT subscription, through your browser
kogen provider login claude-code    # Claude Code token from claude setup-token
kogen provider login anthropic      # Anthropic API key
```

The automatic discovery of `kogen init` needs a ChatGPT login. With only another provider, such as an Anthropic key, use the configuration-first path in step 4 ("Without ChatGPT").

Others are `supergrok`, `opencode-go` and `openai-compatible`. List what is saved (no network access):

```sh
kogen provider list
```

```output provider-list
chatgpt: signed in (<account>)
supergrok: not signed in
opencode-go: not signed in
anthropic: not signed in
...
```

## 4. Initialise the project

In your repository, with a clean committed tree:

```sh
kogen init
```

`init` discovers how the project builds and tests, asks the configured model about its commands, keeps only the checks that pass on your committed tree, sets up acceptance with Cucumber, and commits `.kogen/project.yaml` as `Add Kogen configuration`. To change models, effort or checks later, edit `.kogen/project.yaml` and commit it (see `docs/configuration.md`).

```output init
kogen: detecting the project's commands
...
Initialized Kogen in <repo>
Setup: none
Checks: app
Acceptance: Cucumber bridge added in features/steps
Commit: <commit> Add Kogen configuration
ok git - repository <repo>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
```

Run doctor again; everything should be `ok`:

```sh
kogen doctor
```

```output doctor-after-init
ok git - repository <repo>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
ok commands - app status=<status> in <duration>; acceptance runner reachable
```

### Without ChatGPT

Log in to your provider, for example Anthropic (or the provider you use), then write the configuration yourself instead of letting `init` discover it:

```sh
kogen provider login anthropic
mkdir -p .kogen
```

Create `.kogen/project.yaml` with the complete example below, a Go module project. Adapt its setup, checks and acceptance to your project's real ones. The same model lines are in `docs/presets/anthropic-only.yaml` in the Kogen repository for reference.

```yaml
version: 1
commands:
  setup:
    - 'go mod download'
  fix: []
  checks:
    - {name: test, run: 'go test ./...'}
  acceptance:
    run: 'NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require ''features/steps/*.js'' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"'
    steps_dir: 'features/steps'
protect: []
models:
  shape: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}
  build: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}
  review: {provider: anthropic, model: claude-opus-5-5, effort: medium}
shape_workers:
  enabled: false
```

Leave `.kogen/project.yaml` uncommitted. `kogen init` then takes its leftover-configuration path and commits it as `Add Kogen configuration` together with the `.gitignore` entry for `.kogen/local/`. (If it were already committed, init would only report that Kogen is already initialized and would not add that entry.) Then run init and doctor:

```sh
kogen init
kogen doctor
```

```text without-chatgpt-init
Initialized Kogen in <repo>
Commit: <commit> Add Kogen configuration
```

```text without-chatgpt-doctor
ok git - repository <repo>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
...
```

`kogen doctor` runs the setup, checks and acceptance runner too, so its `commands` line needs `go` installed and the project's own tests green.

## 5. Shape

Write the request as a short file kept outside the repository (a Build needs a clean working tree), then shape it under a slug:

```sh
kogen intent shape greeting ../request.md
```

If the model needs a decision from you, it prints questions and stops:

```output shape-questions
Questions for greeting:
1. Which greeting wording should the feature use?
   a) Hello, world (recommended)
   b) Hi there
Answer one per line as <n>: <letter or your words>, e.g. printf '1: a\n' | kogen intent shape greeting -
```

Write an answers file of `<n>: <letter>` lines and run shape again with it as the file (or pipe the lines on stdin):

```sh
printf '1: a\n' > ../answers.txt
kogen intent shape greeting ../answers.txt
```

```output shape-ready
...
Intent: <repo>/.kogen/intents/greeting/intent.md
Acceptance test: <repo>/.kogen/intents/greeting/acceptance.feature
Step files: features/steps/greeting_steps.js (new)
Model: not applicable — the greeting has no state
Scenarios: 1 (0 fail now, 1 pass now)
...
Next: kogen intent approve greeting
```

The Intent files live in `.kogen/intents/<slug>/`: `intent.md` (the short prose, decisions, source comparison and tests), `acceptance.feature` (executable Gherkin), the step definitions it names, and a Quint `model.qnt` when the change has meaningful state.

## 6. Revise

If the package is ready but needs a correction, do not edit its files: use refine. The sha256 comes from `kogen intent approve <slug>` (step 7); put the correction in a file outside the repository:

```sh
kogen intent refine greeting <sha256> ../correction.md
```

```output refine
...
refined greeting <hash>
Changed: .kogen/intents/greeting/acceptance.feature
Evidence: <path>
Next: kogen intent approve greeting
```

Refine changes only existing owned files, checks the merged package, and preserves the original on failure. It never approves. Edit by hand only before shaping or for things refine refuses, such as new files; those need a new shaping request.

## 7. Approve

```sh
kogen intent approve greeting
```

This shows the card and exits with status 5 without approving anything:

```output approve-card
Intent: greeting — Print the greeting
SHA-256: <sha256>
...
Acceptance
  - The greeting is available (passes now)
Files
  - .kogen/intents/greeting/intent.md
...
Approve with:
  kogen intent approve greeting <sha256>
```

The card shows the source comparison (what of your request is addressed or left out), the approver (your Git identity), the acceptance scenarios and whether they pass now, and the exact protected files the Build may not change. Read it, then approve with the printed hash:

```sh
kogen intent approve greeting <sha256>
```

```output approve
approved greeting <hash>
Next: kogen intent build greeting
```

## 8. Build

```sh
kogen intent build greeting
```

The Build runs in rounds: the builder implements the Intent, Kogen verifies it (acceptance scenarios, model, your checks) and sends failures back, then an independent reviewer investigates and repairs defects, Kogen verifies again, and one commit lands with your own Git configuration.

```output build
building greeting
kogen: building (round 1)
...
kogen: verifying (pass 1)
kogen: pass 1: all checks passed
kogen: reviewing (review 1)
...
kogen: review 1: approve, 0 blocking
kogen: committing
landed greeting <commit> (Build <build-id>)
  checks: acceptance 1/1, model not applicable, app passed
  review: approved
  repairs: 0 · tokens: <tokens> · time: <duration>
```

`landed` names the commit and the Build id; `checks` lists what passed; `repairs` counts the fixes the reviewer made. A Build that stops says why in its last lines and leaves your files and approval as described:

- `build_blocked` (shown as `candidate/build_blocked`): the builder reported a contradiction in the protected files. It is the builder's claim, not proven. Preserve the work and correct the package with the recover, refine and approve route below.
- To clear a blocked Build, run recover with a new directory outside the repository to receive an archive; it then restores your implementation files. Then refine the Intent with the printed `correction.md`, approve the corrected package and build again.
- To continue a Build that stopped for another reason (a provider failure, login expiry, interrupt) in the same checkout, run resume with the Build id.

```sh
kogen intent recover <build-id> --output ../new-private-archive
kogen intent resume <build-id>
```

## 9. Where records live

Everything Kogen records about your runs stays on your machine under `.kogen/local/` in the repository (shaping, refinements, readiness evidence, provenance, runs and recoveries). It is private and not committed. Inspect a run with `kogen intent inspect <run-id>`. To remove the program:

```sh
kogen uninstall
```
