# Getting started

From nothing installed to your first landed Build. You need Git, a Git repository with a clean committed tree, and a model route you can sign in to.
Outputs below come from release v0.1.0-dev.62015185; `<slug>`, `<path>` and `<home>` stand for your own values.

## 1. Install

```sh
curl -fsSL https://get.kogen.dev | sh
```

The installer verifies the release checksum and installs into `~/.local` without administrator rights.
If `~/.local/bin` is not on `PATH`, add the "Add to PATH" line it prints to your shell configuration.
With Homebrew: `brew trust kogenai/tap && brew install kogenai/tap/kogen`.

```sh
kogen version
```

```
kogen v0.1.0-dev.62015185 (2026-11-07)
```

`kogen version` prints `kogen v0.1.0-dev.<sha> (<date>)`.

## 2. Sign in

Pick one route. Each command saves the login privately under `~/.kogen`.

```sh
kogen provider login chatgpt                                          # browser, on the same machine
printf '%s' "$ANTHROPIC_API_KEY" | kogen provider login anthropic     # no browser: an Anthropic API key on stdin
kogen provider login claude-code                                      # interactive terminal: Kogen's own Claude Code signs in
printf '%s' "$CLAUDE_CODE_TOKEN" | kogen provider login claude-code   # piped: stores the token you already have
```

On an interactive terminal, `kogen provider login claude-code` installs Kogen's pinned Claude Code runtime under `~/.kogen/claude-code/` when it is missing, opens its browser sign-in and saves the subscription token privately.
Piped input is storage only: the token is saved, and no runtime is installed and no sign-in runs.
If the install or sign-in fails, a saved login stays unchanged; run `kogen provider login claude-code` again.
`kogen init` never downloads the runtime.
`kogen init` needs one signed-in route; no ChatGPT login is required when another route, for example an Anthropic key, is available.
List what is saved, without network access:

```sh
kogen provider list
```

```
claude-code: token saved (not verified)
claude-code runtime: Claude Code 2.1.312 installed (<home>/.kogen/claude-code/2.1.312/claude)
```
A fresh home has no `claude-code` row.
## 3. Initialise the project

```sh
kogen init
```

Init finds how the project builds and tests, keeps the checks that pass on your committed tree, adds Cucumber acceptance and commits `.kogen/project.yaml` and `.kogen/models.yaml`.

```
Initialized Kogen in <path>
Setup: none
Fix: none
Checks: tests
Protect: none
Acceptance: Cucumber bridge added in features/steps
Commit: 1eb6a4ca Add Kogen configuration
ok install - kogen v0.1.0-dev.62015185 (2026-11-07); node, cucumber and quint run
ok git - repository <path>
ok config - .kogen/project.yaml is valid
ok models - shape, build, review ready
```

The `ok` lines are the readiness report; a failing line is followed by one `  fix:` line.
Next, run `kogen intent shape <slug> <request-file>`.

Without a login, init stops with this error. Sign in by the browser (`kogen provider login chatgpt`) or, with no browser, by an Anthropic key on stdin, then run init again:

```
provider/login: not signed in; run kogen provider login for a supported provider
```

## 4. Shape

Write the request in a file outside the repository (a Build needs a clean working tree), then shape it under a slug:

```sh
kogen intent shape <slug> request.md
```

```
Intent: <path>/.kogen/intents/<slug>/intent.md
Acceptance test: <path>/.kogen/intents/<slug>/acceptance.feature
Step files: features/steps/<slug>__calc.js (new)
Model: not applicable - <reason>
Scenarios: 5 (4 fail now, 1 pass now)
Next: kogen intent approve <slug>
```

If the model needs a decision, it prints numbered questions; answer with `printf '1: a\n' | kogen intent shape <slug> -`.
To correct a ready Intent, run `kogen intent refine <slug> <sha256> <correction-file>`.

## 5. Approve

```sh
kogen intent approve <slug>
kogen intent approve <slug> <sha256>
```

The first prints the card (source comparison, acceptance scenarios, protected files) and exits with status 5 without approving.
The second approves with the hash the card prints and ends with:

```
Next: kogen intent build <slug>
```

## 6. Build

```sh
kogen intent build <slug>
```

The builder implements the Intent, Kogen verifies it and returns failures, an independent reviewer repairs defects, and one commit lands with your own Git identity.

```
building <slug>
kogen: building (round 1)
kogen: verifying (pass 1)
kogen: pass 1: all checks passed
kogen: reviewing (review 1)
kogen: review 1: approve, 0 blocking
kogen: committing
landed <slug> 03c89ee0 (Build e9acffc6)
  checks: acceptance 5/5, model not applicable, tests passed
  review: approved
```

A Build that stops says why in its last lines. After a provider failure, login expiry or interrupt, run `kogen intent resume <Build id>`.
For a Build blocked by a protected-file contradiction, run `kogen intent recover <Build id> --output <new directory>`.
Errors and their next commands: [troubleshooting.md](troubleshooting.md).

## 7. Records and removal

Kogen's records of your runs stay in `.kogen/local/` in the repository, private and uncommitted; `kogen intent list` lists them.
To remove the program:

```sh
kogen uninstall
```

Uninstall removes the program and `~/.kogen/claude-code`. It keeps your saved logins and `~/.kogen/host-id`.
