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

Kogen has no separate check command. Readiness comes from two places: the readiness lines that end `kogen init` (step 4), and the error each command prints when it cannot proceed, which names what is missing and the fix. The readiness lines make no model call and change nothing.

The readiness lines are `install` (the program and its bundled node, cucumber and quint run; fix: reinstall), `git` (you are inside a Git repository and Git has a `user.name` and `user.email`), `config` (`.kogen/project.yaml` exists and is valid) and `models` (every role has a stored login for its provider; fix: `kogen provider login <provider>`, step 3; for `claude-code` roles a stored token or a claude.ai sign-in of Kogen's own runtime, fix: `kogen provider login claude-code`). Each failing line is followed by one `  fix:` line.

A command that cannot proceed prints one of these errors instead:

- A damaged install: `environment/installation_damaged: ...; reinstall Kogen`. Reinstall Kogen (step 1).
- Outside a Git repository: `environment/not_a_git_repo: <path>; run git init first`. Change into your project's repository, or start one with `git init`.
- No configuration: `environment/not_initialized: <root> has no .kogen/project.yaml; run kogen init`. Run `kogen init` inside the project (step 4).
- An invalid configuration: `environment/project_config_invalid` with one `  line <n>: <message>` line per problem. Correct those lines in `.kogen/project.yaml`.
- No model login: `provider/login: not signed in; run kogen provider login <provider>`. Sign in (step 3).
- No Git identity: `environment/git_identity_missing: no Git user.name and user.email; run git config user.name "<name>" and git config user.email "<email>" (global or repository)`.
- Claude Code as an executor: Kogen installs and runs its own pinned Claude Code (`2.1.312`, under `~/.kogen/claude-code/`) at the first role that needs it, never the `claude` on your `PATH`. A runtime that reports another version stops with `Kogen's Claude Code at <path> reports <answer>, not the pinned 2.1.312; remove <dir> to reinstall it`; a download that fails or does not match the pinned SHA-256 installs nothing (`executor/unavailable`); and a runtime without a token is not signed in (``make a token with `claude setup-token` and save it with `kogen provider login claude-code` ``). Without an own Claude Code, make the token with `CLAUDE_CONFIG_DIR="$HOME/.kogen/claude-code/config" "$HOME/.kogen/claude-code/2.1.312/claude" setup-token` once the runtime is installed. `kogen init` never downloads: a runtime that is not installed yet is no problem by itself, and a present one that does not report `2.1.312` is a `claude-code:` problem with the fix `rm -rf <home>/.kogen/claude-code/2.1.312`.

If a check fails on your unchanged tree, a Build still starts and records the failure as a baseline, but it can only land when every configured check passes, so the Intent has to repair that check as well (or you fix the project first).

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

`init` discovers how the project builds and tests, asks the configured model about its commands, keeps only the checks that pass on your committed tree, sets up acceptance with Cucumber, and commits `.kogen/project.yaml` (the commands) and `.kogen/models.yaml` (the model lineup) as `Add Kogen configuration`. To change models or effort later, edit `.kogen/models.yaml` and commit it, or put a role in the host-local, uncommitted `.kogen/local/models.yaml` to change it on one machine; to change checks, edit `.kogen/project.yaml` and commit it (see `docs/configuration.md`).

```output init
kogen: detecting the project's commands
...
Initialized Kogen in <repo>
Setup: none
Checks: app
Acceptance: Cucumber bridge added in features/steps
Commit: <commit> Add Kogen configuration
ok install - <version>; node, cucumber and quint run
ok git - repository <repo>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
```

The last four lines are the readiness lines of step 2; everything should be `ok`. A `fail` line is followed by its fix, and does not change init's exit status.

### Without ChatGPT

Log in to your provider, for example Anthropic (or the provider you use), then write the configuration yourself instead of letting `init` discover it:

```sh
kogen provider login anthropic
mkdir -p .kogen
```

Create `.kogen/project.yaml` with the complete example below, a Go module project. Adapt its setup, checks and acceptance to your project's real ones. The model lineup goes in its own file, `.kogen/models.yaml`: copy it from the second example, which is `docs/presets/anthropic-only.yaml` in the Kogen repository. `.kogen/project.yaml` refuses a `models:` key.

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
```

```yaml models
models:
  shape: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}
  build: {provider: anthropic, model: claude-sonnet-5-5, effort: medium}
  review: {provider: anthropic, model: claude-opus-5-5, effort: medium}
```

Leave `.kogen/project.yaml` and `.kogen/models.yaml` uncommitted. `kogen init` then takes its leftover-configuration path and commits them as `Add Kogen configuration` together with the `.gitignore` entry for `.kogen/local/`. (If it were already committed, init would only report that Kogen is already initialized and would not add that entry.) Then run init:

```sh
kogen init
```

```text without-chatgpt-init
Initialized Kogen in <repo>
Commit: <commit> Add Kogen configuration
ok install - <version>; node, cucumber and quint run
ok git - repository <repo>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
```

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

It also removes `~/.kogen/claude-code`, Kogen's own Claude Code runtime, and keeps your saved logins (including the Claude Code token), `~/.claude` and your own Claude Code.
