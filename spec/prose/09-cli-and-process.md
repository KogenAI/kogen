# 09 CLI and process

One `kogen` program for people and for coding agents that drive it: no TUI, no prompts besides login, no colour, the same output whether or not stdout is a terminal. Command names, grammar, exit codes and the error-line format are fixed for the commands this version has.

**CLI-1 — Commands.** Exactly:

```
kogen context [--json] [--project <checkout>]
kogen completion zsh
kogen intent list [--limit N] [--cursor TOKEN] [--json]
kogen intent usage [RUN-ID] [--lineage] [--json]
kogen intent inspect <run-id> [--json]
kogen intent preflight <slug> [--json]
kogen init
kogen intent shape <slug> <file|->
kogen intent refine <slug> <sha256> <file|->
kogen intent approve <slug> [<hash>] [--by <name>]
kogen intent build <slug> [--context <file>]
kogen intent recover <build-id> --output <directory>
kogen intent resume <build-id>
kogen provider login chatgpt
kogen provider login supergrok
kogen provider list
kogen uninstall
kogen version
kogen help
```

`intent` commands also take `--project <checkout>` (default: the working directory). The checkout read interfaces and their JSON errors are specified below.

**CLI-2 — Grammar.** `--name value` or `--name=value`; options anywhere after the command path; the last repeated option wins; `--` ends options; `-h` is the only short option; a lone `-` is a positional. `--help` or `-h` after a command path prints that path's existing help page (CLI-3), exit 0. `--version` prints the same version line as `kogen version` (CLI-10), exit 0. First match wins: `kogen` and `kogen help` print the top page and a group alone (`intent`, `provider`) its page (exit 0); otherwise `kogen help: unexpected argument '<token>'`, `kogen <group>: unknown command '<sub>'`, `kogen: unknown command '<x>'`, `kogen <path>: unknown option '<opt>'`, `kogen <path>: <opt> needs a value`, `kogen <path>: missing <name>`, `kogen <path>: unexpected argument '<arg>'`, `kogen provider <verb>: unknown provider '<p>' (supported: chatgpt, supergrok)`, `kogen intent approve: <hash> must be 6 to 64 lowercase hex characters`, `kogen intent refine: <sha256> must be 64 lowercase hex characters`. A usage error prints the message, an empty line and the page of the group meant (the top page outside groups), exit 2. Only fresh `intent build` accepts `--context`; every other command path, including resume, rejects it with ordinary unknown-option grammar. The file is resolved relative to the caller working directory, not `--project`; it is never stdin or command text. A missing `--project` directory is `environment/project_unavailable: <path>` (exit 3).

**CLI-3 — Help pages.** Byte-exact.

`kogen --help` and `kogen -h` print the top page below. `kogen <command path> --help` and `kogen <command path> -h` print the existing help page for that path: the top page for commands outside a group, the intent page for paths under `intent`, and the provider page for paths under `provider`. `kogen --version` prints exactly what `kogen version` prints.

`kogen`, `kogen help`:
```
Commands:
  context    Read checkout-local facts (JSON)
  completion zsh  Print standalone Zsh completion
  init       Prepare this Git repository for Kogen
  intent     Shape, approve and build an Intent
  provider   Sign in to a provider and show logins
  uninstall  Remove the installed kogen
  version    Show the Kogen version
  help       List commands

Run kogen <command> to see its subcommands and options.
```

`kogen intent`:
```
Usage: kogen intent <command> <slug> [arguments] [options]

Commands:
  shape <slug> <file|->     Shape an Intent from a request file (- reads stdin)
  refine <slug> <sha256> <file|->  Correct existing files; require fresh approval
  approve <slug> [<hash>]   Show the review card, or approve the Intent
  build <slug>              Build, verify, review and commit the approved Intent
  recover <build-id> --output <directory>  Preserve a protected blocker and clear implementation only
  resume <build-id>         Continue a stopped Build in this checkout
  list                     List packages and Build attempts
  usage [run-id]          Explain local retained provider usage
  inspect <run-id>         Inspect recorded Build evidence
  preflight <slug>         Observe read-only prerequisites

Options:
  --project <checkout>  Project checkout (default: current directory)
  --by <name>           Approver (default: your Git identity)
  --context <file>      Fresh Build diagnostic data only (not resume)
  --output <directory>  Recover only: NEW directory outside the checkout (required)
```

`kogen provider`:
```
Usage: kogen provider <command>

Commands:
  login chatgpt            Sign in with a ChatGPT account
  login supergrok          Sign in with a SuperGrok subscription
  login opencode-go        Save your OpenCode Go workspace key from stdin
  login anthropic          Save your Anthropic API key privately from stdin
  login claude-code        Save your Claude Code token (claude setup-token) privately from stdin
  login openai-compatible  Save an optional key for an OpenAI-compatible host from stdin
  list                     Show which providers Kogen is signed in to

Logins belong to this machine, never to a repo.
```

**CLI-4 — Streams.** stdout carries results, help, usage errors and error lines; stderr carries progress (LOOP-13; shaping prints `kogen: shaping (request <n>)`, `kogen: probe: <command>` and `kogen: checking readiness`), the lock notice (AUT-4) and logs. Kogen's own diagnostic log goes to stderr only: with `KOGEN_LOG_LEVEL=debug` it adds lines that start `[debug] `, and none of them is ever written to stdout. UTF-8, `\n` line ends, no colours.

**CLI-5 — Exit codes:** 0 done; 1 ran and the answer is no; 2 usage, or an argument the caller must fix; 3 environment; 4 provider; 5 needs the caller's decision or action (advisory); 70 Kogen bug; 129 SIGHUP; 130 SIGINT; 143 SIGTERM.

**CLI-6 — Error lines.** `<class>/<reason>: <detail>` on stdout, extra lines indented two spaces; classes `intent`, `check`, `environment`, `provider`, `candidate`, `controller`, `shape`. Each error is defined in its chapter. Shaping stopped by a provider error prints the `provider/…` line, then `shape/provider_failed: shaping stopped on a provider error after its retries; the failed request wrote no files. Run kogen intent shape again, or write the Intent yourself.` (for `login` and `usage_limit` the second sentence is `shaping stopped on a provider error that retrying cannot fix; the failed request wrote no files. Fix the account, then run kogen intent shape again.`). `controller/internal_error: <one line>[; run log: <path>]` (exit 70) is only for Kogen bugs; a failed or interrupted Build, a refused start, a provider problem and a changed approval each have their own reason.

**CLI-7 — Interruption.** On SIGINT, SIGTERM or SIGHUP (SIGHUP is handled like SIGTERM), `kogen` cancels what it is doing. This applies to every command that runs project commands (`shape`, `approve` and `build`). `kogen` starts nothing new, cancels a request in flight, terminates the process groups of every command it started, background ones included (SIGTERM, SIGKILL after 5 seconds), makes no commit even if one was about to happen, and releases the lock. `git commit` is a command like any other and gets SIGTERM; if HEAD moved anyway, Kogen undoes the commit with the compare-and-swap of GIT-6. For `shape` and `approve`, `kogen` prints nothing more and exits 130, 143 or 129 within 15 seconds. For a Build, `kogen` prints `stopped <slug>: interrupted (Build <id8>)`, `candidate/interrupted: Build <id8> stopped by <SIGINT|SIGTERM|SIGHUP>; edits are left in place` and the GIT-8 detail lines, and exits 130, 143 or 129 within 15 seconds; past that it kills the remaining process groups and exits with the same code. Processes that left a command's process group are not tracked. Only a signal to `kogen` cancels: the same signal sent to a command's own process group does not (CLI-9). Model: `run_control.qnt` `InterruptNeverCommits`, `ExitCodes`.

**CLI-8 — Killed kogen.** A `kogen` that is killed (SIGKILL, or anything else it cannot catch) can neither report nor clean up, so the watchdogs of CLI-9 do it: within seconds the process group of every command it started is stopped (SIGTERM, SIGKILL after 5 seconds), and no commit is made after the kill. The lock file of the dead process stays until the next Build removes it with the notice of AUT-4. A commit that already existed when `kogen` was killed — killed between creating it and recording the result — stays on HEAD; Kogen never undoes or repairs it afterwards. `kogen intent resume <build-id>` then reports what Git actually holds: it compares HEAD with the start HEAD in the run record, names the commit it finds (its 8-digit short hash) and creates no second commit. Model: `run_control.qnt` `ExitCodes` (an abrupt end may leave a commit).

**CLI-9 — One program.** `kogen` is one native program (Go, standard library only): it parses the command line, reads caller input, talks to the providers, runs shaping, Builds, verification, review and the commit, and owns the sign-in loopback listener. Installing or running it needs no Erlang, Elixir or other runtime; it starts no daemon, no second Kogen process and no network listener besides the sign-in one. Each project command (setup, fixers, acceptance, checks, the `shell` and `probe` tools, `git commit` with its hooks) runs as `/bin/sh -c` in its own process group under a watchdog: the same `kogen` binary re-executed with the hidden first argument `__kogen_supervise`. Terminal signals reach only `kogen`, because the commands are in other process groups. The watchdog survives SIGINT, SIGTERM and SIGHUP sent to its group, so such a signal reaches only the command and never cancels the Build; cancellation comes only from a signal to `kogen` (CLI-7). When `kogen` ends or dies for any reason, the watchdog stops its command's process group (SIGTERM, SIGKILL after 5 seconds; CLI-8). `kogen` finds `lib/VERSION` and its bundled tools relative to its own resolved path (INS-3); a damaged installation (no `lib/VERSION`) is `environment/<reason>: <detail>; reinstall Kogen` (exit 3). Output of project commands that is valid UTF-8 is kept byte for byte whatever the caller's locale; an invalid byte becomes U+FFFD.

**CLI-10 — Version.** `kogen version` prints `kogen <sha8> (<YYYY-MM-DD>)` — the commit the release was built from and its date — anywhere, without login. A release built from source that is not exactly a commit (a tree with uncommitted changes, or source outside any commit) prints `kogen dev+<hash8> (<YYYY-MM-DD>, uncommitted source)`, where `<hash8>` is the first 8 hex digits of the SHA-256 over, for each source file sorted by path, `<path>\0<sha256 of its bytes>\n`; the source files are `LICENSE`, `NOTICE`, `cli/`, `packaging/` and `docs/`. The line comes from the installed `lib/VERSION`; the installed `lib/VERSION.json` holds the same facts for tools: `{"version": "<sha8 or dev+hash8>", "commit": "<full 40-hex commit or null>", "date": "<YYYY-MM-DD>", "uncommitted": <true|false>}`.

Scenarios: `features/09-cli-and-process.feature`. Model: `quint/run_control.qnt`.

Explicit continuation uses `kogen intent resume <build-id> [--project <checkout>]`; it shares the Build's start path and repository lock (LOOP-10).

Fresh Build diagnostic text is read once by `kogen` before any model request and kept as data, never interpolated into a shell command or argument list. The optional run field is `context: {text: <UTF-8 string>, source_path: <nonempty absolute source label>, sha256: <64 lowercase hex>}`; omission omits the field. `kogen` requires exactly those string fields, valid nonblank UTF-8 text of at most 262144 original bytes, and a matching SHA-256. Malformed data or any supplied context on a non-build command is `intent/context_unavailable` (exit 2) before effects. `kogen` never stats or rereads the label; a valid inaccessible label is usable. Invalid original UTF-8 is rejected at the CLI, not repaired.

## Checkout-local read interfaces

The maintained [version 1 read contract](../../docs/checkout-facts.md) specifies
context, Intent listing/inspection/preflight and standalone Zsh completion. These
interfaces observe facts and never approve, recover or authorize a Build. Local
metadata is ignored private integration evidence, not checkpoint authority.

The usage subcommand is a separate bounded history scan with human and version 1 JSON output, exact filters, grouping and lineage. Its full interface and uncertainty rules are maintained in [usage.md](../../docs/usage.md); context and completion never start that scan.

`intent recover <build-id> --output <directory> [--project <checkout>]` is the explicit
LOOP-7 preservation/implementation-cleanup command, not resume, approval or automatic
Refine. Help and standalone completion expose `recover` and its required output directory.
