# Bash & Read Discipline

## Token Budget

`/context` startup ≤22K. Mid-session ≤80K. Auto-compact 167K. Every Read = tokens.

- Delegate "where is X" to planner subagent — ~100 tokens vs 5K
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

SSH-chain loophole: `ssh host "cmd | head/grep/tail"` and `ssh host "cat file"` are **all still forbidden**. Required pattern: (1) `ssh host "cmd 2>&1 > /tmp/<slug>.log"`, (2) `scp host:/tmp/<slug>.log /tmp/<slug>.log`, (3) Read tool on the local file.

## Bash Tool

`2>&1` captures stdout+stderr. Trust output. No output = success. Piping `head`/`tail`/`grep` causes truncation — run bare, Read log.

## Ports

Never hardcode. Use `$PORT` or `PROJECT_CONTEXT.md`. Example: `curl http://localhost:${PORT:-4000}/health`

## Git Paths

All git commands use relative paths (workspace root is cwd). NEVER hardcode `/Users/<user>/...` in git operations.

## Git mv

`git mv <src> <dst>` — parent of `<dst>` must exist first. Use `mkdir -p <dst-parent>` before `git mv`.

## Planner Bash Constraints

**Bash redirects to session logs are FORBIDDEN** (all forms: heredocs, `>`, `>>`, brace-group redirects to `codegen/logging/`). Bash tool_use entries are invisible to transcript-based hook discovery. **Workaround**: Use the Edit tool on session logs instead.

**Read tool blocks on rule files** (developer.md, testing-liveview.md, testing.md, reviewer.md, committer.md). Use Grep tool with `-B`/`-A` context to locate anchor text instead; supply verbatim anchors in plan prose.

## Newline-List Membership Testing

POSIX-safe membership check on newline-separated values (e.g., `yq` output):

```bash
LIVE_IDS=$(yq '.[] | select(.generated == true) | .id' registry.yaml)

is_live() {
    printf '%s\n' "$LIVE_IDS" | grep -qxF "$1"
}
```

- `grep -qxF` = quiet + exact-line match + fixed-string (no regex). Avoids substring false-matches (e.g., `no-cat-pipe` vs `no-cat-pipe-x`).
- `printf` preserves newlines when iterating the string literal. `set -u`-safe; empty `LIVE_IDS` returns 1 (not found).
- Preferred over Bash 4+ arrays (`declare -A`) for macOS 3.2 compatibility.

## Python Relative-Path Portability (os.path.relpath)

`os.path.relpath()` is purely textual — it does NOT resolve symlinks. On macOS, `/var` is a symlink to `/private/var`, and `mktemp -d` can return paths under either prefix. When computing a relative path from a temp dir (e.g., `.scaffold.tmp.XXX` under `/var/folders/...`) to a final target under `/Users/...`, the relpath calculation sees different string prefixes and produces wrong depth. **Fix**: call `os.path.realpath()` on BOTH arguments BEFORE `os.path.relpath()`:

```python
from os.path import relpath, realpath
target_real = realpath(target_path)
start_real = realpath(start_dir)
result = relpath(target_real, start_real)
```

This ensures symlinks are resolved to their real paths before the textual comparison. Example: Bash helper for scaffolding:

```bash
_relpath() { python3 -c 'import os,sys; print(os.path.relpath(os.path.realpath(sys.argv[1]), os.path.realpath(sys.argv[2])))' "$1" "$2"; }
```

Relevant context: codegen-scaffold `run_integrate_stage` uses relpath to emit relative symlinks for AGENTS.md/CLAUDE.md and codegen/\* targets. Compute against the FINAL link-base dir (not temp build dir), else the relpath carries extra `../` levels and dangles after the `mv`.

## Bash Path Canonicalization: Symlink Resolution in Tests

On macOS, `mktemp -d` may return paths under `/var/folders/...` (symlinked to `/private/var/folders/...`). Any test constructing paths from `$TMP_ROOT` and asserting the paths against hook output (which canonicalizes via `pwd -P`) must canonicalize `TMP_ROOT` before use:

```bash
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"  # Resolve symlinks to canonical form
```

This ensures that relative-path construction (e.g., `$TMP_ROOT/.claude/worktrees/$name`) produces the same canonical path that hook code would compute via `cwd_real="$(cd "$cwd" && pwd -P)"`. Omitting canonicalization causes `grep -qxF "worktree $worktree_path"` matches to fail when testing against porcelain output (which emits absolute paths).

## Scaffold Makefile-Injection Printf: Hard Tabs via `\t` Escapes

When scaffolding injects multi-line Makefile targets via `printf`, recipe lines MUST use hard tabs (not spaces). Use `\t` escape sequences inside single-quoted printf format strings — printf interprets them as hard tabs in the rendered file. **Pattern**: `printf 'ci:\n\t@cmd1\n\tcmd2\n' >> Makefile`. Do NOT hand-type literal tab or space characters; the escape sequence guarantees portability across macOS and Linux. Existing scaffold mutations use this idiom throughout (`shared/scaffold/<stack>/scaffold.sh`); new Makefile injections reuse the same approach. Validate via `make <target>` run (Makefile parser rejects spaces in recipe indentation with a clear error).

## mise Trust Records Location (XDG_STATE_HOME vs XDG_DATA_HOME)

`mise trust` records trusted-configs in `$XDG_STATE_HOME/mise/trusted-configs/` (default: `~/.local/state/mise`), NOT in `$XDG_DATA_HOME/mise/`. Round-trip tests that override `HOME` to a temp dir must export BOTH `MISE_DATA_DIR` (data) AND `MISE_STATE_DIR` (state) pointing to real user dirs, or `mise exec` exits 1 with a missing-trust error. Correct pattern:

```bash
export MISE_DATA_DIR="$HOME/.local/share/mise"
export MISE_STATE_DIR="$HOME/.local/state/mise"
```

Pre-existing test fixture gap: when pi-extension npm install errors are surfaced (not masked by `| sed`), a test running in a temp HOME will hit `mise exec` → trust lookup failure → exit 1 (real error, not a false negative). Capturing real MISE_STATE_DIR before HOME override prevents spurious failures and surfaces real build issues.

## Launcher Flag Parsing: Pre-Process Before Resolver Loops

When a launcher dispatcher accepts optional flags (e.g., `--new`) that must NOT be passed to downstream arg-parsing logic (e.g., draft-resolver loops that `exit 1` on unmatched positionals), strip the flag BEFORE the resolver loop runs:

```bash
# Parse --new BEFORE the resolver loop that exit 1's on unmatched args
FORCE_NEW=0
_filtered_args=()
for _a in "$@"; do
    if [[ "$_a" == "--new" ]]; then
        FORCE_NEW=1
    else
        _filtered_args+=("$_a")
    fi
done
set -- "${_filtered_args[@]+"${_filtered_args[@]}"}"
```

The `set -- "${arr[@]+"${arr[@]}"}` pattern rebuilds positionals from the filtered array, preserving `$#` and `$1` for the resolver loop. Failure to pre-process flags causes the resolver to misread the flag as a positional argument and exit 1 on no match.

## Trailing+Defaulted Positional Arguments (Extensible Functions)

Extending multi-caller bash functions with new optional parameters: use trailing positional with `${N:-}` default-empty pattern. Zero churn for callers omitting the new arg.

Pattern: `local witness="${16:-}"` in function body (defaults to empty string when arg 16 is missing). Append `""` to pre-existing calls on INCONCLUSIVE/CLEAR branches (already-known-cause paths) → single-line change per call site. Opaque-FAILED branches call a new helper to compute the value and pass it explicitly.

**Benefit**: 19 pre-existing callers + 3 test helpers all work unchanged; only 2 new call sites (opaque-FAILED branches) need conditional logic to compute + pass the argument. Preferred over re-numbering positional args (which would require editing every caller).
