# Troubleshooting

Each entry gives the exact message, what it means and the next command. `<path>`, `<root>`, `<name>`, `<email>` and `<id>` stand for your own values.
`kogen version` prints `kogen v0.1.0-dev.<sha> (<date>)`; quote it when you report a problem.

## Before a command can run

### Not a Git repository

```
environment/not_a_git_repo: <path>; run git init first
```

You ran the command outside a Git repository. Change into your project, or start one:

```sh
git init
```

### No Git identity

```
environment/git_identity_missing: no Git user.name and user.email; run git config user.name "<name>" and git config user.email "<email>" (global or repository)
```

Kogen commits with your Git identity, and Git has none. Run both commands from the message.

### Not initialised

```
environment/not_initialized: <root> has no .kogen/project.yaml; run kogen init
```

The project has no Kogen configuration yet. Run `kogen init` in the repository.

### Not signed in

```
provider/login: not signed in; run kogen provider login for a supported provider
```

A role needs a login you have not saved. The refusal is several lines: this one, then lines naming the routes.
Sign in with your browser, or with no browser pipe an Anthropic API key on standard input:

```sh
kogen provider login chatgpt
printf '%s' "$ANTHROPIC_API_KEY" | kogen provider login anthropic
```

`kogen init` needs only one signed-in route; it does not need ChatGPT when another route is available.

## Build ids and Intents

### Not a Build id

```
candidate/recovery_unsupported: "<id>" is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; kogen intent list lists Build attempts
candidate/resume_unsupported: "<id>" is not a Build id; a Build id is 8 lowercase hexadecimal characters, such as 0a1b2c3d; kogen intent list lists Build attempts
```

`kogen intent recover` and `kogen intent resume` take a Build id, not an Intent slug. Find the id:

```sh
kogen intent list
```

### Intent not found

```
intent/not_found: Intent does not exist
```

`kogen intent refine`, `approve` and `build` print this when no Intent has that slug. The message names no next command.
Run `kogen intent list` to see the Intents and Build attempts of the project, and check the slug and the folder you are in.

### Inspect outside a project

`kogen intent inspect <id>` outside a Kogen project answers with raw JSON whose reason is `not_project`.
Inside a project, an unknown id names `kogen intent list`. Change into the project, or run `kogen init` there.

## Setup in a non-Go repository

```
environment/setup_failed: Setup setup-1 failed (status=127).
```

When you shape in a repository that is not a Go project, setup can fail with `go: command not found` in the setup output.
The configured setup command calls `go`. Edit `commands.setup` in `.kogen/project.yaml` to your project's own setup (see [configuration.md](configuration.md)), commit it, and shape again.

## Output that looks wrong

These are what Kogen does today:

- `kogen intent --help` and `kogen provider --help` print the group listing. A command's own page is `kogen intent <command> --help`.
- The no-login refusal is a multi-line message, not one line.
- `intent/not_found` names no next command.
- `kogen intent inspect <id>` outside a project prints raw `not_project` JSON.
- After an environment refusal, Kogen can still print a `kogen: shape time` line.
