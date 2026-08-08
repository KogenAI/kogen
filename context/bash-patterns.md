# Bash Stub Testing Patterns

Patterns for writing deterministic bash test stubs, especially stateful stubs with per-invocation behavior variation.

## Stateful Counter Stubs: Fresh Root Per Logically-Distinct Assertion

A bash test stub that uses a stateful counter file (incrementing on each invocation to return different values/codes per call) must get its own fresh stub root directory if the test case uses the stub in multiple, logically-distinct assertions. Reusing a stateful stub root across two assertions causes state leakage: the counter has already advanced past the "fails on first call" branch from an earlier assertion in the same case, so a later RED-then-GREEN probe won't see the same per-call behavior sequence.

**Fix**: Isolate stateful stubs via separate `make_stub_bin` calls per assertion, giving each a fresh stub root (e.g., `$BASE_TMP/assert1_bin`, `$BASE_TMP/assert2_bin`). The counter file resets to 0 when a new stub root is created, and each logically-distinct assertion (including RED probes) exercises the stub's call sequence from the start, proving the behavior independently.

**Example**: When proving a continue-past-failure guard, a RED probe must use its own stub root so the stateful counter begins at 0 and the first call fails as intended (not skipped because the counter has already advanced from an earlier assertion in the same case).

## RED-then-GREEN Proof Isolation for Stateful Stubs

When validating that a guard correctly handles failure (e.g., a `set +e/rc/set -e` sandwich that isolates a command's failure from the enclosing `set -euo pipefail` shell), the RED-then-GREEN proof must be fully isolated from prior assertions in the test case:

1. GREEN path (main assertion): tests that the guard works correctly (batch continues despite a cluster failure).
2. RED proof: demonstrates that WITHOUT the guard a bare failing command would abort the enclosing shell.

The RED proof must NOT reuse the stateful stub from the GREEN assertion — the counter has already advanced. Instead:

- Use a fresh stub root for the RED probe.
- Invoke the stub with the same stub configuration (counter begins at 0, fails on first call).
- Prove that without the guard (no `set +e` sandwich), a failing stub under `set -euo pipefail` causes the subshell to abort (rc=1).
- Prove that WITH the guard (with sandwich), the batch continues (rc=0) and subsequent clusters are still processed.

This isolates RED and GREEN at the stub level, ensuring the RED probe actually exercises the failure path rather than hitting a skipped branch because the counter advanced in an earlier assertion.

## Test Environment Isolation: Ambient Env-Var Leakage

Bash hook `_test.sh` files run directly (not via `run-tests.sh`) inherit ambient shell env vars. If the developer's own agent shell sets `CLAUDE_ROLE`, direct test invocations see the leakage and may hit unintended code paths. Example: Test 45 in `orchestrator-no-source-edit_test.sh` uses `run_test` (not `run_test_role`), so it reads the ambient env directly; if `CLAUDE_ROLE=build` is set, the test wrongly selects the build-role path and fails for an unrelated reason.

**Fix**: When running hook `_test.sh` files interactively (outside the CI clean shell), strip inherited role vars before invocation:

```bash
env -u CLAUDE_ROLE bash <test>.sh
```

This is NOT needed when tests run via `harnesses/claude/hooks/run-tests.sh` in a clean CI environment — only when invoking directly from within an agent session. The issue is test-invocation discipline (direct runs), not the tests themselves (run-tests.sh context cleans the env).

## git show Redirect Source-Sourcing Trap

When creating a RED-then-GREEN proof by redirecting a hook script via `git show HEAD:<path> > /tmp/copy.sh`, the copied script may use relative sourcing (e.g., `source "$(dirname "$0")/lib/hooks-lib.sh"`). The `dirname` of `/tmp/copy.sh` is `/tmp/`, not the original source directory, so the relative path breaks and the sourced file is not found.

**NEVER fix this by writing the fixture INTO the live hooks source dir** (`harnesses/claude/hooks/`), in-place or otherwise — even as a leading-dot "hidden" file. That directory is walked by `hook_registrations.py` (`Path.glob("*.sh")` matches dotfiles too — a stray non-hook file there hard-fails `make install` with a missing-HOOK-MANIFEST-fields error) and by concurrent test/install consumers under `make test`'s parallel run. A trap-based cleanup only fires on a clean exit; a killed process stranded the file permanently, breaking every subsequent `make install` until someone deletes it by hand. This happened in production: two fixtures (`no-cat-pipe_test.sh`, `pre-commit-guard_test.sh`) synthesized a pre-fix hook body directly in `harnesses/claude/hooks/` and, under `make install` racing `make test`, caused a manifest error and a discarded $27 build cycle.

**Fix**: write the synthetic fixture into a fresh `mktemp -d` scratch dir, and symlink the real `lib/` (and any other sourced sibling, e.g. `_role.sh`) back into that scratch dir so the fixture's relative `dirname "$0"` sourcing still resolves:

```bash
PRE_FIX_DIR="$(mktemp -d)"
ln -s "$SCRIPT_DIR/lib" "$PRE_FIX_DIR/lib"
PRE_FIX_HOOK="$PRE_FIX_DIR/my-hook.pre-fix.sh"
trap 'rm -rf "$PRE_FIX_DIR"' EXIT
cat >"$PRE_FIX_HOOK" <<'PREFIXEOF'
#!/bin/bash
# ...historical buggy body, verbatim...
source "$(dirname "$0")/lib/hooks-lib.sh"
...
PREFIXEOF

# RED phase: run against $PRE_FIX_HOOK, confirm the historical bug reproduces
# GREEN phase: run against the real hook, confirm the fix holds
```

This keeps `dirname "$0"` resolutions working (via the symlink) without ever writing a non-hook file into the real source directory. `run-tests.sh` asserts post-suite that `harnesses/claude/hooks/` carries zero dotfiles as a backstop against regressions of this pattern.

## Pitfalls

- **Bash heredoc loop state** — use `while <<EOF`, not pipe.
- **Bash subshell export isolation**: Pipe subshells (`printf ... | fn`) execute in a subshell — exports + variable mutations invisible to outer process. Fix: use file redirect (`while ... done < file` or `fn < "$stdin_file"`) instead of pipe.
- **`local` under `set -u`** — fails in if/elif at script scope. Bare assignment OK. Reset at loop top.
- **Portable sed** — `sed -i ''` (BSD) ≠ GNU. Use Python for portability, or temp-file rewrite: `sed 'EXPR' file >"${file}.tmp" && mv "${file}.tmp" file`.
- **Bash grep `\b` hyphen false-positive** — Use `(^|[^a-zA-Z0-9-])token`.
- **Bash 3.2** — No `declare -A`, `wait -n`, `${VAR@L}` case-fold. Use `tr '[:upper:]' '[:lower:]'`.
- **Path canonicalization** — Canonicalize both sides for `/var`↔`/private/var` symlinks via `hooks_realpath` (bash) or `resolveRealPath` (TS).
- **Heredoc expansion** — Unquoted `<<EOF` expands; `<<'EOF'` doesn't. Match stub convention: single-quoted uses bare `$*`; unquoted needs `\$*`.
- **[shared] bash `continue` in nested heredoc loops breaks inner loop only** — `continue` inside `while read -r` heredoc-fed inner loop only breaks inner loop, not outer main loop. Place `break`/logic at outer loop level to break out of edge-scan after first-unmet-dep found.
- **Grep footguns** — `-v` deletes before keep. BRE `\(` = GROUP; use `-F` for literals. **Always use `grep -qF -- "$needle"`** when needle may be flag-shaped (e.g., `--harness=X`); macOS grep silently misparses without `--`.
- **[shared] `grep -c` + fallback double-prints** — `grep -c` exits 1 on no-match; `|| echo 0` fires and emits second `0`. Drop fallback, rely on grep-c alone.
- **Shell test binary stubbing** — Symlink tools, omit target, filter `$PATH`. Use `command -v` (builtin). `export -f` doesn't propagate to subprocesses; use PATH-stub pattern instead. Pattern: `PATH="$BIN_DIR:$PATH" bash "$HOOK"`.
- **PATH-mutation runtime order** — New exec branch added textually AFTER PATH-prepend still inherits it at runtime. Trace EXECUTION flow (not file order); textually-later can run textually-after PATH-mutation.
- **Hook stub isolation for sourced files** — Pre-sourcing doesn't work. Create per-test `CODEGEN_DIR` subdir with stub, invoke with `CODEGEN_DIR="$TMP_ROOT/tN" bash "$HOOK"`.
- **jq null extraction in hook payloads** — `jq -r '.field'` on JSON null emits `"null"` (not empty). Always use `jq -r '.field // empty'` for optional fields.
- **yq null-safety** — Every yq array op → `(.field // [])` guard. `.field | join(",")` crashes when field null/absent.
- **Conditional final statements** — Use `if/then/fi` instead of `&&` (flips exit code).
- **Cleanup exit code** — `RESULT=0; inner_cmd || RESULT=$?; cleanup; exit $RESULT`.
- **Fail-closed refute in tests** — to prove a script aborts BEFORE an irreversible action, use a shimmed subprocess marker: stub the irreversible command to record if called, then `refute` the marker was set.
- **`${PIPESTATUS[1]}` captured immediately after pipeline** — Any intervening command resets the array. Pattern: `find | xargs ...; _rc=${PIPESTATUS[1]}` on next line only.
- **PIPESTATUS through tee pipe: use set +e / set -e boundary pattern** — Pattern: `set +e; cmd | tee file; rc="${PIPESTATUS[0]}"; set -e`. Do NOT use `|| true` — it zeroes PIPESTATUS.
- **Per-attempt test variants via `eval`** — Use integer counter + eval for per-attempt body overrides (Bash 3.2-safe, injection-safe).
- **Sourced bash library in Bash tool context** — Use `bash -c 'source <lib> && fn'` for bash-specific syntax.
- **`--no-config` flag isolates tmpdir tests** — Use `--no-config` for tools with hierarchical config discovery to block ancestor leakage.
- **Fail-loud on guaranteed-dependency absence** — Don't skip tests for tools guaranteed by `make install` (prettier, node). Fail loud; soft-skip masks environment assumption violations.
- **Hoist variable assignments before guards** — Assign ABOVE the branch that uses them, not inline.
- **`set -u` with git commands** — Guard both call (`2>/dev/null` on git) and comparison (`-n "$var"` before arithmetic) to handle empty repos safely.
- **Git repo init in test setup** — Test fixtures calling `git commit` must call `git init` themselves. Pattern: `git init -q` + `git config user.email/name` + `git add/commit`.
- **`guard_breadcrumb` helper portability** — Use `stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || echo 0` for mtime (BSD/GNU/fallback).
- **Test fixture leak: `git reset HEAD` vs `git checkout`** — `git reset HEAD <file>` unstages but leaves appended working-tree content. Later tests re-reading the file see the leaked append. Fix: `git checkout -- <file>` after reset to revert both staging and working tree.
- **[local] RED-then-GREEN for verdict-string flips** — When converting output value (e.g., INCONCLUSIVE → FAIL), test against PRE-fix source (red, prove it fires) then POST-fix (green). Layer proof where verdict is produced, not routed.
- **[local] RED-then-GREEN for source-grep guard tests via scratch copies** — When adding a source-grep guard, prove it catches violations: copy target to `/tmp`, inject forbidden token, run test against injected copy (RED), confirm real source re-passes (GREEN).
- **[local] RED-then-GREEN for bash assertions via `git show HEAD:<path>` when fix uncommitted** — Pull pre-fix source via `git show HEAD:<file> > /tmp/<file>.pre.sh` while working-tree fix is uncommitted (RED test against pre-fix), then test against fixed source in working tree (GREEN).
- **[shared] RED-then-GREEN proof via floating `git show HEAD:<file>` self-invalidates once fix lands** — When a proof depends on `git show HEAD:<file>` to pull pre-fix "broken" state, the moment the fix commits to HEAD the proof self-invalidates. Fix: synthesize hardcoded pre-fix fixture reproducing exact historical bug instead of relying on floating HEAD state. **NEVER write that fixture into `harnesses/claude/hooks/`** (breaks `hook_registrations.py`'s HOOK-MANIFEST parity, strands on a killed test) — write it into `mktemp -d` with `lib/` (and any sourced sibling) symlinked back for relative sourcing; see "git show Redirect Source-Sourcing Trap" above.
- **[shared] macOS symlink mismatch** — Plain `cd` doesn't resolve `/var` → `/private/var`. Assert basename not full path.
- **[local] Ambient CLAUDE_ROLE/CODEGEN_BUILD_START_TS leak into unscoped hook tests** — Fix: `env -u CLAUDE_ROLE -u CODEGEN_BUILD_START_TS bash "$HOOK"` when running standalone outside `make test`.
- **[shared] Ambient env leaks into hermetic test fixtures** — Use `env -u VAR1 -u VAR2` for "neither set" test; omitting one fails.
- **[shared] Copying to `/tmp` breaks relative paths** — `HOOK="$(dirname "$0")/hook.sh"` breaks when `$0` is `/tmp/copy` (dirname is `/tmp`). Use in-place diffs via `git diff`/`git show` instead.
- **Bash isolation**: `sed -n '/<fn>/,/<close>/p' | eval` avoids argparse `exit` when testing helpers.
- **Timestamps**: `YYYYMMDD_HHMMSS` sorts lexically ≡ chronologically. Use `[ "$ts1" \< "$ts2" ]` for portable compare.
- **Bash patterns**: `#` and `[]` are glob-special in `${var%%pattern}` expansions. Hook simulation may fail; test literal code.
- **Hook deletion: full-vocabulary grep** — search filename, id, deny-message across ALL files post-deletion. A hook name can survive in `registry.yaml`, test comments, or a sibling hook's skip-list after the `.sh` itself is removed; a narrow grep on the deleted filename alone misses those. Sweep the full vocabulary (filename, HOOK-MANIFEST id, deny-message substrings) before declaring the deletion complete.
- **`run-tests.sh` is NOT a registered hook and has NO paired `*_test.sh`** — it's a utility runner, not a hook subject to registration/enforcement. No `run-tests.sh_test.sh` pairing exists. (1) The runner is untested by the hook-test suite by design. (2) Edits require manual verification via `make test`. (3) Fixing the runner needs no test-file changes.
- **`bash -n` misparses zsh completion scripts** — use `zsh -n` for zsh files, not `bash -n`.

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

Pre-existing test fixture gap: when npm install errors are surfaced (not masked by `| sed`), a test running in a temp HOME will hit `mise exec` → trust lookup failure → exit 1 (real error, not a false negative). Capturing real MISE_STATE_DIR before HOME override prevents spurious failures and surfaces real build issues.

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

**Auto-discovery scopes**: the `run-tests.sh` auto-discovery step scans `*_test.sh` files ONLY under `harnesses/claude/hooks/`. Files in `harnesses/shared/` or extension subdirs are NOT auto-discovered. A test outside hooks/ must be explicitly wired into the Makefile `harness-parity` target's `for t in` list. Example: `harnesses/shared/experiment-prune_test.sh` is registered via `"$(SCRIPT_DIR)/harnesses/shared/experiment-prune_test.sh"` in the list.

**Manifest exemption for `_test.sh` files**: `hook_registrations.py` excludes files matching `*_test.sh` from HOOK-MANIFEST parity checks via the `--exclude-pattern=_test.sh` flag (set in the Makefile `harness-parity` target). A bash hook test does NOT require a `# HOOK-MANIFEST:` header block (unlike non-test hooks). Test files are auto-discovered and run as unit tests; they do not define hooks and are not registered in `settings.json`.

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

Non-hook bash helpers belong in `harnesses/shared/` (alongside `retryable-errors.sh`). NEVER place a helper in `harnesses/claude/hooks/` unless it carries a `# HOOK-MANIFEST:` header. Reason: `hook_registrations.py` requires every non-`_`, non-`_test.sh` `.sh` file in hooks/ to have a HOOK-MANIFEST registry entry. A helper there triggers hook-parity failure.

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

A test stub's trailing statements after a heredoc are reachable only if the heredoc is NOT wrapped in `exec` — `exec cat "$FIXTURE_PATH"` replaces the shell process, so a later `exit $N` never runs. Fix: drop `exec`; put `cat "$FIXTURE_PATH"` then `exit "${STUB_EXIT:-0}"` on separate lines. Makes exit code configurable per test (`STUB_EXIT=3 run_dispatch ...`) without per-case stub duplication.

## Printf Format Strings: Hyphen-Prefix Escape Requirement

A `printf` format string starting with `-` (e.g. `"- item: %s\n"`) misparses as an option flag ("invalid option"). Use `printf -- "- item: %s\n" "$value"` — `bash -n` won't catch this; it's runtime-only.

## jq Filter Rebinding in select()

`select(known_kinds | index(.ev))` — piping an array literal into the filter rebinds `.` to that array, so `.ev` indexes the array, not the original item. Fix: `select(. as $item | known_kinds | index($item.ev))`. Also: `--slurpfile VAR file` already gives `$VAR` as the array — `$VAR[0]` double-wraps; use `$VAR` or `$VAR[]` directly.

## Trigger Keywords

stateful stub, counter file, test isolation, RED-then-GREEN proof, bash test patterns, ambient env leakage, CLAUDE_ROLE, git show, dirname sourcing, PIPESTATUS, jq null safety, yq null safety, portable sed, macOS symlink, grep footguns, PATH stub, pathname expansion, noglob, set -f, hook deletion full-vocabulary grep, run-tests.sh not a registered hook, zsh completion bash -n misparse, newline-list membership testing, os.path.relpath symlink resolution, mise trust records, scaffold makefile printf tabs, module-scope case block variables, test discovery harness parity wiring, bash test set parity relative paths, bash module organization hook-manifest, launcher flag pre-processing, trailing defaulted positional arguments, stub heredoc exit code control, printf hyphen prefix escape, jq filter rebinding select
