# Bash & Read Discipline

## Token Budget

`/context` startup ≤22K. Mid-session ≤80K. Auto-compact 167K. Every Read = tokens.

- Where available (orchestrator/shape/debug/ops — a leaf agent never spawns another role/subagent): delegate "where is X" to an `Explore` subagent — ~100 tokens vs 5K. Leaf roles (developer/reviewer) lack this tool; use Grep/Glob directly.
- Read with `offset`/`limit` for large files. ✅ Grep tool, not `Bash(grep)`

## Forbidden Bash Tokens (hard list)

| Token                                  | When forbidden                | Use instead                                                                                                    |
| -------------------------------------- | ----------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `cat <file>`                           | Reading any file in repo      | Read tool                                                                                                      |
| `head <file>` / `head -n N <file>`     | Reading file head             | Read tool with `limit:`                                                                                        |
| `tail <file>` / `tail -n N <file>`     | Reading file tail             | Read tool with `offset:`                                                                                       |
| `head` / `tail` piped onto bash output | Truncating command output     | Run bare with `2>&1`, Read the result                                                                          |
| `grep <pattern> <file>`                | Searching repo files          | Grep tool                                                                                                      |
| `git diff` (no path/range)             | Inspecting changes            | `git diff --name-only` first, then scoped `git diff -- <path>`                                                 |
| `git log` (no scope and no cap)        | Browsing history              | Scope with `--` path **or** cap with `-N` (one is enough; `git log origin/main..HEAD` is fine — bounded range) |
| `python3 -c "import json..."`          | Parsing JSON from a file      | Read tool on the JSON file                                                                                     |
| `time <cmd>`                           | Wrapping a test/build command | Run bare — `time` swallows the output you need                                                                 |
| Bare `mix test` (or any test runner)   | Test loop                     | Filter — file, `--only` tag, or line number                                                                    |

SSH-chain loophole: `ssh host "cmd | head/grep/tail"` and `ssh host "cat file"` **still forbidden** (discipline only — `no-cat-pipe`'s `ignore_quoted: true` doesn't catch this). Required: (1) `ssh host "cmd 2>&1 > /tmp/<slug>.log"`, (2) `scp host:/tmp/<slug>.log /tmp/<slug>.log`, (3) Read tool locally.

## Bash Tool

`2>&1` captures stdout+stderr. Trust output. No output = success. Piping `head`/`tail`/`grep` causes truncation — run bare, Read log.

## Ports

Never hardcode. Use `$PORT` or `PROJECT_CONTEXT.md`. Example: `curl http://localhost:${PORT:-4000}/health`

## Git Paths

All git commands use relative paths (workspace root is cwd). NEVER hardcode `/Users/<user>/...` in git operations.

## Moving/Renaming a File

`git mv` is denied for every agent (`pre-commit-guard.sh`) — it stages, and no agent stages; `codegen-commit` does that after you. Use plain `mv <src> <dst>` (parent of `<dst>` must exist first: `mkdir -p <dst-parent>`) and leave the rename unstaged in the working tree.

## Session-Log Bash Constraints

**Bash redirects to session logs are FORBIDDEN** (all forms: heredocs, `>`, `>>`, brace-group redirects to `codegen/logging/`). `codegen-log` is the sole writer — route every log write through it.

Nothing denies Read on rule files — `rule-edit-reach` only advises on Edit/Write/MultiEdit to `shared/rules/**`, never blocks. Prefer Grep with `-B`/`-A` for locating an anchor over a wide Read anyway (token cost, not a hook).

**See**: `context/bash-patterns.md` for newline-list membership testing, Python relpath symlink resolution, bash test path canonicalization, scaffold Makefile-injection printf tabs, mise trust records, sourced-helper `-e` discipline, module-scope case-block variables, test-discovery/harness-parity wiring, bash test set parity, bash module organization, launcher flag pre-processing, trailing positional args, stub-heredoc exit codes, printf hyphen-prefix escaping, and jq filter rebinding.
