# Kogen

Kogen takes one requested feature through Shape, Build, Verify, Review and Commit in your own Git repository.
You write the request; Kogen turns it into an approved Intent with executable acceptance tests, builds it with a model and checks it with your project's own checks.
An independent model reviews the result, and one commit lands. More at [kogen.dev](https://kogen.dev).

## Install

```sh
curl -fsSL https://get.kogen.dev | sh
```

Or with Homebrew. Homebrew 7 does not load formulae from third-party taps until the tap is trusted, so trust it first:

```sh
brew trust kogenai/tap && brew install kogenai/tap/kogen
```

Platforms: macOS arm64, macOS x86-64, Linux x86-64 and Linux arm64.
The full install page is [kogen.dev/get-started](https://kogen.dev/get-started/).
Check the install with `kogen version`.

## Quickstart

Run these in your own Git repository. `kogen init` needs a signed-in route: if it says `not signed in`, run the login line first.

```sh
kogen init
kogen provider login chatgpt          # or claude-code, anthropic: see docs/getting-started.md
kogen intent shape <slug> request.md  # keep request.md outside the repository
kogen intent approve <slug>           # shows the card; run again with the hash it prints
kogen intent build <slug>
```

`kogen init` prints:

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

`kogen intent build <slug>` ends with:

```
kogen: committing
landed <slug> 03c89ee0 (Build e9acffc6)
  checks: acceptance 5/5, model not applicable, tests passed
  review: approved
```

## For coding agents

Agents working in a Kogen project: make changes through `kogen intent shape`, `approve` and `build`, and read the request, Intent and acceptance files in `.kogen/intents/<slug>/`.
Run `kogen help` for every command.

## More

- [docs/getting-started.md](docs/getting-started.md): install to your first landed Build
- [docs/configuration.md](docs/configuration.md): `.kogen/project.yaml` and the model lineup
- [docs/troubleshooting.md](docs/troubleshooting.md): each error message and the command that fixes it
- [docs/testing-rules.md](docs/testing-rules.md): which tests a change needs
- [spec/](https://github.com/KogenAI/kogen/tree/main/spec): the specification, plus reference notes in `spec/reference/`
