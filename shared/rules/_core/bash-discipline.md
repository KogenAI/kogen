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

## Sourced Helpers — No Inherited `-e` Flag

Bash helpers sourced into a `set -e` launcher must use `set -uo pipefail` (omit `-e`) at file scope. Each sourced file has its own `set` context, so `-e` is not inherited. However, when a helper is sourced into a `set -e` launcher, a bare non-zero command in the helper will still trigger the caller's `-e` and abort. **Fix**: every fail-open step must end with `|| true`. The only intentional non-zero is a deliberate `return 1` on a not-found error (allowed because `return` is the final simple command before `exit $?`, not subject to `-e`).

```bash
#!/usr/bin/env bash
set -uo pipefail   # NO -e

helper_fn() {
    cmd1 2>/dev/null || true     # Fail-open
    cmd2 || true                 # Fail-open
    [ -d "$path" ] || return 1   # Intentional error
}
```

## Module-Scope Variables Accessible at Function Scope in Case Blocks

In Bash, when a function runs a `case` statement that references a variable outside the function body, declare that variable at **module scope** (not `local`) to ensure case-arm blocks can access it. The `case` statement body executes in the same shell context as the case construct itself, not in a subshell; a `local` variable declared in an outer function scope is visible WITHIN that function, but when a case block (even inside the function) needs to read or update the variable for use by LATER code at module scope, declare it as a module-scoped global. Example:

```bash
# render_stderr is MODULE SCOPE — not local to any function
render_stderr=""

run_render_check() {
    local raw rc
    # ... capture stderr to temp file ...
    render_stderr=$(cat "$err")    # Updates module scope
    rm -f "$err"

    case "$render_verdict" in
        INCONCLUSIVE:*)
            # Later code (outside this function) references $render_stderr
            # — case block must read module-scoped variable, not a local copy
            inc_detail="${render_verdict#INCONCLUSIVE:}"
            ;;
    esac
}

# Caller at module scope:
case "$render_verdict" in
    INCONCLUSIVE:*)
        # This block accesses $render_stderr populated by run_render_check
        append_ve_section "INCONCLUSIVE: $inc_detail — $render_stderr"
        ;;
esac
```

The case-arm body in `run_render_check` runs in the function's context but assigns to the module-scope `render_stderr` variable. Without module-scope declaration, code AFTER the function call cannot access the value. Do NOT use `local render_stderr=""` at function scope if a case-arm block (or subsequent code) needs to read/update it for downstream use.

## Test Discovery & Harness Parity Wiring

**Auto-discovery scopes**: `run-tests.sh:33` discovers `*_test.sh` files ONLY under `harnesses/claude/hooks/`. Files in `harnesses/shared/` or extension subdirs are NOT auto-discovered. A test outside hooks/ must be explicitly wired into the Makefile `harness-parity` target's `for t in` list (lines 144–147). Example: `harnesses/shared/experiment-prune_test.sh` is registered via `"$(SCRIPT_DIR)/harnesses/shared/experiment-prune_test.sh"` in the list.

**Manifest exemption for `_test.sh` files**: `hook_registrations.py:329` excludes files matching `*_test.sh` from HOOK-MANIFEST parity checks via the `--exclude-pattern=_test.sh` flag (Makefile:316). A bash hook test does NOT require a `# HOOK-MANIFEST:` header block (unlike non-test hooks). Test files are auto-discovered and run as unit tests; they do not define hooks and are not registered in `settings.json`.

## Bash Test Set Parity — Use Relative Paths, Not Basenames

When a bash test compares two sets of file paths (e.g., "files on disk" vs. "files listed in INDEX"), use **relative paths** for the comparison, NOT basenames. Basenames create collision risks:

**Collision risk**: The codebase has files with the same basename spread across different folders — for example:

```
roles/developer.md
stacks/phoenix/developer.md
stacks/static/developer.md
```

A basename-set comparison silently passes when one of two same-named files is deleted. The set `{developer.md}` appears unchanged even though `roles/developer.md` was deleted — the basename matcher still finds a `developer.md` match under a sibling stack folder.

**Fix**: Reconstruct each file's relative path (e.g., `roles/developer.md` or `stacks/phoenix/developer.md`) and compare the relative-path sets via `comm`. Use a bidirectional comparison (`comm -23` for add-parity, `comm -13` for delete-parity) to detect files missing from INDEX and rows in INDEX with no file on disk.

**Example**: When asserting INDEX↔filesystem parity (cf. session 20260625_022858), reconstruct each INDEX-listed path from indented tree structure (2 spaces per nesting level) into a sorted set, then compare against disk via `find ... | sed ... | sort`. A basename-only comparison would incorrectly pass when multiple same-named files exist in different folders.

## Bash Module Organization

Non-hook bash helpers belong in `harnesses/shared/` (alongside `retryable-errors.sh`). NEVER place a helper in `harnesses/claude/hooks/` unless it carries a `# HOOK-MANIFEST:` header. Reason: `hook_registrations.py:329` requires every non-`_`, non-`_test.sh` `.sh` file in hooks/ to have a HOOK-MANIFEST registry entry. A helper there triggers hook-parity failure.

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

## Stub-Heredoc Exit-Code Control

When a test stub uses a heredoc (e.g., heredoc-based mock pi binary emitting JSONL fixture bytes), the stub's trailing statements are reachable only if the heredoc is NOT wrapped in `exec`. Pattern: `exec cat "$FIXTURE_PATH"` replaces the shell process, making a subsequent `exit $N` unreachable — stub always exits with the exit code of `cat`, not the forced code. **Fix**: drop `exec`, then append the exit statement on a new line: `cat "$FIXTURE_PATH"` newline `exit "${STUB_EXIT:-0}"`. This allows the stub to emit fixture bytes AND force a non-zero exit code for failure-path testing. The stub's exit code becomes configurable via env var passed through the test harness (e.g., `STUB_EXIT=3 run_dispatch ...`), enabling single-stub-script multi-case testing without per-case stub duplication.

## Printf Format Strings: Hyphen-Prefix Escape Requirement

`printf` format strings that start with a literal hyphen (e.g., `"- item: %s\n"` or `"--flag %s\n"`) are misparsed as option flags by `printf` (runtime error: "invalid option"). **Always use `printf --` when the format string itself begins with `-`** to signal end-of-options. Pattern: `printf -- "- item: %s\n" "$value"` rather than `printf "- item: %s\n" "$value"`. This escapes the format string's leading `-` and prevents misparse. Syntax validation via `bash -n` passes (the format string is syntactically valid); the bug is runtime-only, revealed only when `printf` executes the format string and sees a leading `-` character.
