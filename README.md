# Kogen

**Shape the feature. Leave the build to Kogen.**

Make the product and UX decisions that define the feature. Specify technical decisions when they matter. Kogen handles the implementation, checking, independent review, rework, and resulting commit.

Kogen is being built from a small core that can shape and build further changes
to Kogen itself. The aim is to grow the rest of the product through that loop:
shape the next feature, approve its Intent, and let Kogen carry out the Build.
The core is a starting point, not the finished product.

The core currently uses Codex CLI and runs inside this repository. Installing
Kogen into arbitrary projects and using other model providers are future work.
The broader design remains a longer-term direction, open to change as Kogen develops.

This repository is being opened quietly so the ongoing work and its history
can be inspected. Kogen is Almir Sarajčić’s personal engineering project.

## Get started

Use Elixir 1.20 with Erlang/OTP 29, Git, Make, and an authenticated Codex CLI on your PATH. The current verification target is macOS; other platforms are unverified. Codex CLI 0.153.4 is the current verification target. Provider-backed work uses your Codex account.

From a checkout:

```sh
mix deps.get
make check
mix kogen.shape
```

Describe one feature. As the Shaper, discuss its behavior and tradeoffs with Kogen’s Shaping Controller, inspect the Draft it writes, and explicitly approve it in that conversation. Approval moves the Intent from `.kogen/intents/drafts/<slug>/` to `.kogen/intents/approved/<slug>/`.

Exit the shaping conversation, then build its chosen slug:

```sh
mix kogen.build <slug>
```

Start Build on a clean branch with a commit at HEAD. Kogen implements the approved feature, runs checks, obtains an independent review, and commits the accepted result with its completed Intent and evidence. A stopped Build returns an error and keeps its work available for inspection. Review the error and working tree before starting again; automatic recovery is not implemented yet.

## The loop

- **Shaper** is the human who shapes the feature with Kogen and approves the Intent.
- **Intent** captures the shaped feature precisely enough for Kogen to build it autonomously.
- **Build** implements, checks, independently reviews, and reworks when necessary.
- **Commit** records the checked and accepted implementation of one Intent.

The Developer's Stop hook owns `make check`. Failed checks are corrected within the same conversation. By default, at most two outer resumptions are available for later verification or review failures. An exhausted Build stops rather than claiming success.

Every scenario's `verified_by` is a YAML list of Make target names, such as `[check]`. The real lifecycle fixture has a bounded check target; it never invokes the full live suite recursively.

## Configuration and local data

Edit the tracked `.kogen/config.yaml` to select the available model and effort for each role. The defaults are Sol high for shaping and review, and Terra high for development.

Kogen loads the tracked project hooks and launches Codex CLI with approval, sandbox, and hook-trust prompts bypassed so the Build can run autonomously.

Drafts, Approved Intents, Build locks, and raw runtime logs are local and ignored by Git. Complete Intents and concise verification evidence accompany successful commits. `KOGEN_HARNESS` can select an executable for testing; ordinary use resolves `codex` on PATH.

## Run the checks

```sh
make check     # Offline checks and the complete fake-harness lifecycle
make live      # Real public shaping, approval, build, review, and fixture commit
```

Fetch dependencies first. `make check` then runs formatting, warnings-as-errors compilation, strict Credo, Boundary enforcement, ordinary tests, and fake lifecycle tests without provider requests.

`make live` requires network access, Codex authentication, `expect`, and `rsync`. It creates a disposable fixture under this checkout, uses scripted approval only for that test fixture, and retains run evidence under `.kogen/runtime/`. It tests real failed-check correction in one Developer session and reviewer-directed rework with an exact Developer resume and a fresh accepting Reviewer. Set `KOGEN_LIVE_LOG_DIR` to retain that evidence elsewhere.

## Project and contact

Kogen continues work that began as Optimum Codegen. The retained history predates this core; commit `3f5af338` marks the **Start from clean slate** boundary. Earlier implementation instructions are historical; the fuller design remains a revisable direction for future features.

Read the [Origins](https://kogen.dev/origins/) for the story behind Kogen.

Questions and inquiries: [contact@kogen.dev](mailto:contact@kogen.dev).

Copyright 2026 Optimum Tech, LLC. Licensed under [Apache 2.0](LICENSE).
