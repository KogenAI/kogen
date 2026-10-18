# 09 CLI and process

One `kogen` command for people and for coding agents that drive it: no TUI, no prompts besides login, no colour, the same output whether or not stdout is a terminal. Command names, grammar, exit codes and the error-line format are fixed for the commands this version has.

**CLI-1 — Commands.** Exactly:

```
kogen init
kogen intent shape <slug> <file|->
kogen intent refine <slug> <sha256> <file|->
kogen intent approve <slug> [<hash>] [--by <name>]
kogen intent build <slug>
kogen provider login chatgpt
kogen provider list
kogen uninstall
kogen version
kogen help
```

`intent` commands also take `--project <checkout>` (default: the working directory). No other command or option exists.

**CLI-2 — Grammar.** `--name value` or `--name=value`; options anywhere after the command path; the last repeated option wins; `--` ends options; `-h` is the only short option; a lone `-` is a positional. `--help` or `-h` after a command path prints that path's existing help page (CLI-3), exit 0. `--version` prints the same version line as `kogen version` (CLI-10), exit 0. First match wins: `kogen` and `kogen help` print the top page and a group alone (`intent`, `provider`) its page (exit 0); otherwise `kogen help: unexpected argument '<token>'`, `kogen <group>: unknown command '<sub>'`, `kogen: unknown command '<x>'`, `kogen <path>: unknown option '<opt>'`, `kogen <path>: <opt> needs a value`, `kogen <path>: missing <name>`, `kogen <path>: unexpected argument '<arg>'`, `kogen provider <verb>: unknown provider '<p>' (supported: chatgpt)`, `kogen intent approve: <hash> must be 6 to 64 lowercase hex characters`, `kogen intent refine: <sha256> must be 64 lowercase hex characters`. A usage error prints the message, an empty line and the page of the group meant (the top page outside groups), exit 2. A missing `--project` directory is `environment/project_unavailable: <path>` (exit 3).

**CLI-3 — Help pages.** Byte-exact.

`kogen --help` and `kogen -h` print the top page below. `kogen <command path> --help` and `kogen <command path> -h` print the existing help page for that path: the top page for commands outside a group, the intent page for paths under `intent`, and the provider page for paths under `provider`. `kogen --version` prints exactly what `kogen version` prints.

`kogen`, `kogen help`:
```
Commands:
  init       Prepare this Git repository for Kogen
  intent     Shape, approve and build an Intent
  provider   Sign in to ChatGPT and show the login
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

Options:
  --project <checkout>  Project checkout (default: current directory)
  --by <name>           Approver (default: your Git identity)
```

`kogen provider`:
```
Usage: kogen provider <command>

Commands:
  login chatgpt      Sign in with a ChatGPT account
  list               Show whether Kogen is signed in

Logins belong to this machine, never to a repo.
```

**CLI-4 — Streams.** stdout carries results, help, usage errors and error lines; stderr carries progress (LOOP-13; shaping prints `kogen: shaping (request <n>)`, `kogen: probe: <command>` and `kogen: checking readiness`), the lock notice (AUT-4) and logs. The Elixir core's log and boot output never reach stdout. UTF-8, `\n` line ends, no colours.

**CLI-5 — Exit codes:** 0 done; 1 ran and the answer is no; 2 usage, or an argument the caller must fix; 3 environment; 4 provider; 5 needs the caller's decision or action (advisory); 70 Kogen bug; 129 SIGHUP; 130 SIGINT; 143 SIGTERM.

**CLI-6 — Error lines.** `<class>/<reason>: <detail>` on stdout, extra lines indented two spaces; classes `intent`, `check`, `environment`, `provider`, `candidate`, `controller`, `shape`. Each error is defined in its chapter. Shaping stopped by a provider error prints the `provider/…` line, then `shape/provider_failed: shaping stopped on a provider error after its retries; the failed request wrote no files. Run kogen intent shape again, or write the Intent yourself.` (for `login` and `usage_limit` the second sentence is `shaping stopped on a provider error that retrying cannot fix; the failed request wrote no files. Fix the account, then run kogen intent shape again.`). `controller/internal_error: <one line>[; run log: <path>]` (exit 70) is only for Kogen bugs; a failed or interrupted Build, a refused start, a provider problem and a changed approval each have their own reason.

**CLI-7 — Interruption.** On SIGINT, SIGTERM or SIGHUP (SIGHUP is handled like SIGTERM), `kogen` asks the core to cancel. This applies to every command that runs project commands (`shape`, `approve` and `build`). If `kogen` itself dies, the core sees end of file on its stdin and cancels the same way. The core starts nothing new, cancels a request in flight, terminates the process groups of every command it started, background ones included (SIGTERM, SIGKILL after 5 seconds), makes no commit even if one was about to happen, and releases the lock. `git commit` is a command like any other and gets SIGTERM; if HEAD moved anyway, Kogen undoes the commit with the compare-and-swap of GIT-6. For `shape` and `approve` the core stops the same way, `kogen` prints nothing more and exits 130, 143 or 129 within 15 seconds. For a Build, `kogen` prints `stopped <slug>: interrupted (Build <id8>)`, `candidate/interrupted: Build <id8> stopped by <SIGINT|SIGTERM|SIGHUP>; edits are left in place` and the GIT-8 detail lines, and exits 130, 143 or 129 within 15 seconds; past that it kills the core and the group and exits with the same code. Processes that left the command's process group are not tracked. Model: `run_control.qnt` `InterruptNeverCommits`, `ExitCodes`.

**CLI-8 — Core crash.** If the core exits without a result, `kogen` kills the core's process group and the process groups of every command it started, then reports what Git actually holds: it compares HEAD with the start HEAD in the run record. Unchanged: `controller/internal_error: the Kogen core stopped unexpectedly (status <n>); nothing was committed; run log: <path>`. Moved by the Build's commit: `controller/internal_error: the Kogen core stopped unexpectedly (status <n>) after creating commit <sha8>, before checking it; inspect it with git show <sha8>; run log: <path>`. Exit 70 either way; Kogen does not try to repair it. Model: `run_control.qnt` `ExitCodes` (a crash may end with or without a commit).

**CLI-9 — Go/Elixir bridge.** `kogen` (Go) starts the core (Elixir release) in its own process group for each invocation, so terminal signals reach only `kogen`, which forwards them as messages. They exchange one JSON object per line over the core's stdin and stdout; the core's stderr passes through. The first exchange is `{"type":"hello"}` both ways; a core that does not reach `hello` is `environment/core_unavailable: <detail>; reinstall Kogen` (exit 3). Caller input (request, answers, a pasted login URL) is read only by `kogen` and sent as message data. The core is started with `+Bi +fnu` (UTF-8 file names whatever the caller's locale), so the BEAM ignores SIGINT and never enters its break handler; cancellation reaches the core only as a protocol message from `kogen`. No BEAM distribution, daemon or network listener; the login loopback listener belongs to `kogen` and forwards the redirect to the core. Messages are UTF-8 JSON text: valid UTF-8 in a command's output arrives byte for byte, and an invalid byte arrives as U+FFFD.

**CLI-10 — Version.** `kogen version` prints `kogen <sha8> (<YYYY-MM-DD>)` — the commit the release was built from and its date — anywhere, without login. A release built from source that is not exactly a commit (a tree with uncommitted changes, or source outside any commit) prints `kogen dev+<hash8> (<YYYY-MM-DD>, uncommitted source)`, where `<hash8>` is the first 8 hex digits of the SHA-256 over, for each source file sorted by path, `<path>\0<sha256 of its bytes>\n`; the source files are `mix.exs`, `LICENSE`, `NOTICE`, `config/`, `lib/`, `rel/`, `cli/`, `packaging/` and `docs/`.

Scenarios: `features/09-cli-and-process.feature`. Model: `quint/run_control.qnt`.
