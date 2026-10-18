# 04 Building

A Build is Kogen's own model/tool loop: a builder conversation with four tools that edits the checkout until verification (05) is green and review (06) approves. There is no time or token limit on a Build; a Build ends in exactly one of these ways: `commit` (landed), `baseline_changed`, `head_moved`, `hook_changed_commit`, `commit_failed`, `context_exhausted`, `review_invalid`, `review_blocked`, `provider` or `interrupted`.

**LOOP-1 — Build directly.** After preflight, the Build starts the builder conversation on `models.build` with the approved Intent and project context. There is no separate planning model request. The builder may plan its work within that conversation.

**LOOP-2 — Prompt.** The builder's first message holds the Intent's `intent.md` (its `## Tests` section lists the tests to add or update), `acceptance.feature` and `model.qnt`, the text of `docs/testing-rules.md` (SET-6), the root `README.md`, the configured commands, the protected paths with the rule that approval freezes them and changing them ends the Build, the LOOP-5 rules for commands (stdin is closed; run long-running commands in the background with output to a log file). Editable dependency manifests do not permit weakening, removing or bypassing checks or changing actual verification configuration. Preserve every configured check and its behavior; whole-file protection of a combined check-definition manifest has no dependency-only exception. The builder follows the table of section 2 of the testing rules, the case rules of section 3 and the restrictions of section 4, and runs the affected tests as it works (VER-13). Never `AGENTS.md` or `CLAUDE.md`.

**LOOP-3 — Tools.** Exactly:

| Tool | Arguments | Result |
| --- | --- | --- |
| `shell` | `command` | exit status and combined stdout and stderr |
| `read_file` | `path`, optional `start_line`, `end_line` | numbered lines, or an error |
| `write_file` | `path`, `content` | `ok`, or an error |
| `finish` | `summary` | starts verification |

There is no patch tool.

**LOOP-4 — File rules.** `read_file` and `write_file` resolve paths against the repository root. `write_file` refuses protected paths (VER-8) as a tool error, not a Build failure: `refused: <path> is part of the approved acceptance baseline`.

**LOOP-5 — Shell.** A `shell` call runs `/bin/sh -c <command>` in the repository root, in a new process group, with stdin closed (`/dev/null`), so a command that asks for input fails at once instead of waiting. No command has a time limit. The call returns when its `sh` process exits, with the exit status and the combined stdout and stderr (stderr included even when stdout is empty). A long-running or never-ending command — a dev server, a watch mode — is started by the builder in the background (`<command> > <log file> 2>&1 &`); the builder reads its log file and stops it (`kill`) with further `shell` calls. When the Build ends — commit, failure or Ctrl-C (CLI-7) — Kogen terminates the process groups of every command it started, background ones included.

**LOOP-6 — Responses.** Each response is streamed (GPT-7); tool calls are assembled from their argument fragments and run in order. A call with invalid arguments or an unknown tool gets an error result; the Build goes on.

**LOOP-7 — Finish.** A `finish` call, or a response without tool calls, ends the round: Kogen runs the fixers and verification (05), then review (06) after a green pass. Failing pre-review checks become the next builder message. A green candidate enters one independent review/fix stage (06); its repairs receive external final verification and failures remain with that reviewer. Unresolved substantive review blockers stop with preserved work instead of returning to the builder. The builder cannot end its own stage by giving up.

**LOOP-8 — Output size.** A tool result given to the model is at most 16 KiB in all: the first 4 KiB, the marker `[... <n> bytes omitted ...]`, then the last bytes that still fit.

**LOOP-9 — Context exhaustion.** When the provider reports that the conversation no longer fits the model's context, the Build ends with `candidate/context_exhausted: the conversation no longer fits <model>'s context; edits are left in place` (exit 1).

**LOOP-10 — Run record.** Each Build writes `.kogen/local/runs/<build-id>/log.jsonl` (requests with model, effort, usage and `wall_ms`; tool calls and results, at most 1 MiB each; verification passes; reviews; the outcome) and `result.json`. Credentials never appear (GPT-10). Request-start notices name the role/model/effort on stderr; response notices report usage and wall time without copying response content.

**LOOP-11 — Environment.** Setup, `shell` calls, fixers, checks, the acceptance command and Quint run with stdin closed, without a time limit, and with the caller's environment unchanged except for the two acceptance variables of VER-3 `KOGEN_NODE` (the absolute path of Kogen's own Node, INS-4) `KOGEN_CUCUMBER` (the `node_modules` folder of the Cucumber Kogen ships, INS-2), which the acceptance commands of SET-10 use, and `KOGEN_QUINT` (Kogen's Quint `cli.js`, which a shaping probe runs with `KOGEN_NODE` to check a model before submitting, SHP-10); Kogen adds nothing else, and never its credentials. A real `shell` call of the installed default configuration succeeds.

**LOOP-12 — Tools.** Before any model request, shaping and Builds check that `git` and `/bin/sh` are available and — when the Intent has a model — that Kogen's own Node (the path recorded in `<prefix>/lib/kogen/node-path`, INS-4) and its bundled Quint exist. A Build then runs `commands.setup` (AUT-5) and afterwards checks the first word of each configured command, so executables that setup creates count: Kogen skips leading `NAME=value` words and the shell's own `(`, `{` and `!` in front of the program, and runs `/bin/sh -c 'command -v <word>'` in the repository root, which also finds shell builtins. The generated runner's `"$KOGEN_NODE"` word resolves to the installed Node path before this lookup. Shaping checks them the same way after its setup (SHP-2). Missing: `environment/tool_missing: <name> is not available` (exit 3; for Node and Quint the detail names the path and says to reinstall Kogen). Quint always runs with exactly these resolved paths (VER-5), never through the caller's `PATH`.

**LOOP-13 — Progress.** During a Build, stderr gets one line per step: `kogen: running setup-<n>: <command>` (also in shaping and readiness), `kogen: checking <name> before the Build changes anything`, `kogen: building (round <n>)`, `kogen: verifying (pass <n>)`, then `kogen: pass <n>: all checks passed`, `kogen: pass <n>: <names> failed` or `kogen: pass <n>: files changed while the checks ran: <paths>`, `kogen: reviewing (review <n>)`, then `kogen: review <n>: <verdict>, <k> blocking`, and `kogen: committing`.

Scenarios: `features/04-building.feature`. Model: `quint/build.qnt`.
