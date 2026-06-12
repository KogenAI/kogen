# Bash & Read Discipline

## Token Budget

`/context` startup ≤22K. Mid-session ≤80K. Auto-compact 167K. Every Read = tokens. Read once per file per session.

- project planner subagent (planner-phoenix, planner-html, etc.) for "where is X" — ~100 tokens vs 5K
- Read with `offset`/`limit` for large files
- ✅ Grep tool, not `Bash(grep)`

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

SSH-chain loophole: `ssh host "cmd | head"`, `ssh host "cmd | grep ..."`, `ssh host "cmd | tail"`, `ssh host "cat file"` are **all still forbidden** — the pipe/cat runs on the remote, output is still truncated or unstructured before it reaches you. Required pattern for ANY remote inspection:

1. `ssh host "cmd 2>&1 > /tmp/<slug>.log"` — redirect remote output to a remote tmp file.
2. `scp host:/tmp/<slug>.log /tmp/<slug>.log` — pull it local.
3. Read tool with `offset`/`limit` on `/tmp/<slug>.log`; Grep tool to search it.

Never chain `ssh host "... | head"`, `... | grep`, `... | tail`, `... | wc -l`, or `cat /tmp/remote.log` over ssh. The remote pipe is the same anti-pattern as a local pipe — full output is the goal, not a truncated peek.

Bash output is already shown to you. Re-running the same command (local OR `ssh host "..."`) with a different pipe (`| head`, `| grep`, `| tail`, `| wc -l`) to "narrow down" the output is the anti-pattern — the full output is already in your context from the first run. Read it.

2nd inline `ssh host "cmd | ..."` variant in a session → stop. Stage to `/tmp/<slug>.log` on remote, `scp` local, Read. 3rd inline bash variant of the same idea (local or remote) → stop. Write `/tmp/<slug>.sh`, run it once.

When a command produces output too large for one turn, redirect to `/tmp/<slug>.log` (`cmd 2>&1 > /tmp/<slug>.log`), then Read the log with `offset`/`limit`. Same for remote: `ssh host "cmd 2>&1 > /tmp/<slug>.log"` then `scp` then Read.

## Bash Tool

`2>&1` captures stdout+stderr. Trust output.

- No output = success
- Piping `head`/`tail`/`grep` causes truncation — run bare, Read log

## Bash Dispatch Patterns

**COMMON_FLAGS array** — dispatch scripts with both interactive and non-interactive modes use a shared flags array to avoid duplication and conditional branching. Separates mode-invariant flags (e.g., `--dangerously-skip-permissions`, role system-prompt) from mode-specific flags (e.g., print family: `--print`, `--no-session-persistence`, `--output-format`). Build the common array once, splice into both exec paths:

```bash
COMMON_FLAGS=(--dangerously-skip-permissions)
[[ -f "$SP_FILE" ]] && COMMON_FLAGS+=(--system-prompt "$(cat "$SP_FILE")")

# Later, both modes use:
exec claude "${COMMON_FLAGS[@]+...}" "$MODE_SPECIFIC" ...
```

**Empty-array-safe expansion** — under `set -u`, a bare `"${ARR[@]}"` fails if array is unset or empty. Use `"${ARR[@]+"${ARR[@]}"}"` for optional splicing — expands to the array contents if present, or nothing (without error) if empty:

```bash
set -u  # bare ${ARR[@]} would error if ARR is unset
exec cmd "${ARR[@]+"${ARR[@]}"}" other_args  # safe even if ARR=() or unset
```

**`local` keyword in conditional blocks under `set -u`** — `local` in `if`/`elif` body (main script scope, not function) silently fails under `set -u` if the subsequent variable expansion is unbound — produces no output, no error, script continues. Remove `local` keyword; use bare assignment `VAR=value`. Function scope: `local` is safe.

**Unbound variable in default-value expansion** — `${VAR}` inside `${OTHER:-node "$VAR/path"}` still fails under `set -u` if `VAR` is unset, even though `OTHER` has a default. Use `${VAR:-}` to make unset safe within expansions.

## IFS Multi-Character Join Pitfall

**`IFS=', '; echo "${arr[*]}"` uses ONLY the first character of IFS as separator** — to join with `', '` (comma-space), use `printf '%s, ' "${arr[@]}"` then strip trailing comma:

```bash
# WRONG — separator is only the first char ','
IFS=', '; echo "${arr[*]}"  # → "a, b,c" (space is ignored)

# CORRECT — printf respects the full string
printf '%s, ' "${arr[@]}" | sed 's/, $//'  # → "a, b, c"
```

This is bash builtin behavior and applies across all platforms (bash 3.2+). Using `${arr[*]}` for multi-char separators is a silent failure pattern.

## Cache Mechanics

Stack rules baked at install via Jinja `{% include %}`. Do NOT runtime-load already-included rules.

## Ports

Never hardcode. Use `$PORT` or `PROJECT_CONTEXT.md`.

```bash
curl http://localhost:${PORT:-4000}/health
```

## Git Paths

All git commands use relative paths (workspace root is cwd). `git add ./file`, `git diff -- ./path/to/file`, `git log -- ./src/` all work from project root. NEVER hardcode `/Users/<user>/...` in git operations — breaks CI and cross-machine execution.

## Git mv

`git mv <src> <dst>` — parent of `<dst>` must exist first; `git mv` does NOT create intermediate directories. Use `mkdir -p <dst-parent>` before `git mv`.

## Path-Gating Heuristic (has_path idiom)

When a hook must distinguish full-suite runs from single-file runs (e.g., deny `mix test --cover` but allow `mix test --cover test/foo_test.exs`), use the `has_path` idiom:

```bash
has_path=$(printf '%s' "$COMMAND" | grep -oE '[^[:space:]]+' | grep -E '(/|\.exs$)' | head -1 || true)
if [ -z "$has_path" ]; then
    deny "Bare command runs full suite..."
fi
```

**Reuse, do NOT inline**: this idiom is trusted across multiple guards. Duplicate definitions → multiple sources of truth.

**Limitation**: heuristic admits false positives. A flag value containing `/` (e.g., `--env MIX_ENV=test/config`) may match as a path. Severity: low — contrived invocation patterns. Inherent to the approach; not a regression vs. guards that do not gate on path presence.

**TS port difference**: when porting to TypeScript (e.g., pi-harness), test the FULL command string for path presence, NOT a prefix-stripped version. Elixir `mix test --cover <path>` may appear in any token order; a TS guard that strips `mix test ` before testing path presence would miss `mix test <path> --cover`.

## Transactional Multi-Step File Creation

When a script must orchestrate multiple file mutations that should either all succeed or all fail (no partial state), use a **temp parent + trap** pattern:

```bash
# Create temp dir on same filesystem as final target (atomic mv)
TEMP_PARENT="$(mktemp -d "$(dirname "$target_dir")/.work.tmp.XXXXXX")"
trap 'rm -rf "$TEMP_PARENT"' EXIT

# Run all mutations against TEMP_PARENT/slug
some_mutation "$TEMP_PARENT/$SLUG"
another_mutation "$TEMP_PARENT/$SLUG"

# Atomic move into final position
mkdir -p "$(dirname "$target_dir")"
mv "$TEMP_PARENT/$SLUG" "$target_dir"

# Success — disarm trap
trap - EXIT
rm -rf "$TEMP_PARENT"
```

Ensures: if any mutation fails, trap cleanup removes partial state; if move succeeds, trap is disarmed and final cleanup is explicit. The temp parent must be a sibling (same filesystem) for `mv` to be atomic.

## Portable sed (-i Syntax)

**BSD `sed -i ''` (macOS system sed) is NOT portable to GNU sed (Linux).** Portable pattern:

```bash
TEMP_FILE=$(mktemp)
filter_cmd >"$TEMP_FILE"  # e.g., sed, awk, any transformation
if cmp -s "$TEMP_FILE" "$TARGET"; then
    rm "$TEMP_FILE"       # No change — clean up
else
    mv "$TEMP_FILE" "$TARGET"  # Atomic replace
fi
```

This pattern is idempotent (cmp check ensures nothing changes if the output is identical) and works on both BSD and GNU sed. Use `install.sh` and `uninstall.sh` as canonical references. NEVER use `sed -i` without a fallback; always prefer the `mktemp/cmp/mv` pattern for maximum portability.

## Bash 3.2 Compatibility (macOS system bash)

**`declare -A` associative arrays require bash ≥4.0; macOS system bash is 3.2 and lacks them.** Portable pattern for collecting unique keys:

```bash
# Instead of: declare -A keys; keys[$key]=1
# Use: indexed array + awk to filter values by prefix

declare -a values=()
values+=("prefix/value1" "other/value2" "prefix/value3")

# Extract values matching prefix (awk approach):
awk -v r="prefix/" 'index($0, r) == 1 { print }' <(printf '%s\n' "${values[@]}")
```

For bash-native key-value accumulation on bash 3.2:

1. Use indexed arrays for values.
2. Use `awk` or `grep` to filter by key prefix.
3. Never rely on `declare -A` in cross-platform scripts.

Reference: `post-developer-format.sh` uses this pattern to filter env vars safely on both macOS and Linux.

## Post-Condition Assertions in Mutations

Each mutation script should validate both preconditions (file exists, anchor present) and postconditions (expected lines added, placeholders resolved) before returning success. Fail loudly rather than silently:

```bash
# Precondition
if [ ! -f "$TARGET" ]; then
    echo "[mutation.sh] ERROR: $TARGET not found" >&2
    exit 1
fi

# Mutation logic
# ...

# Postcondition
if ! grep -qF "expected marker" "$TARGET"; then
    echo "[mutation.sh] ERROR: post-condition failed — marker not found after patch" >&2
    exit 1
fi
```

Prevents silent failures that would surface only when the app is run. Template renderers (e.g. `eex_render.sh`) should also fail if leftover unresolved `<%= ... %>` placeholders remain in output.

## Cleanup Wrappers & Exit Code Propagation

When wrapping a command in a cleanup block (e.g., `bash -c "cmd; rm -rf $TMP"`), the inner command's exit code is lost if cleanup succeeds. Pattern:

```bash
# WRONG: cleanup succeeds → exit 0 even if cmd failed
bash -c "cmd; rm -rf $TMP"

# CORRECT: capture exit, cleanup, then propagate
RESULT=0
inner_cmd || RESULT=$?
cleanup_code
exit $RESULT
```

For functions with cleanup-on-exit via `trap`, use the same pattern:

```bash
run_pin_check() {
  local rc=0
  # ... work ...
  rm -rf "$TMP" || true  # cleanup must not override rc
  return $rc
}
```

Capture the inner command's exit code BEFORE cleanup runs, then propagate it after cleanup completes. This ensures the caller sees the actual success/failure of the work, not the cleanup side-effect.

## Install Scripts in Hermetic Test Environments

When an install script runs in a hermetic test environment where `$HOME` is changed (e.g., test fixture with temp home dir), avoid binaries routed through tool shims (e.g., mise shims in `~/.local/share/mise/shims/`):

- Symptom: `npx`, `node`, `prettier` operate via `~/.local/share/mise/shims/` which consult `$MISE_DATA_DIR` (defaults to `$HOME/.local/share/mise`) for tool trust records. Changing `$HOME` breaks the trust lookup → shims cannot locate the real binary.
- **Do NOT trust shims in hermetic contexts.** Either:
  1. Use absolute paths to the real binary (outside shims), OR
  2. Scan `$PATH` for non-shim entries (exclude paths containing `"shims"`) to find the real binary.
- Example: instead of `npx prettier`, find the real prettier binary: `grep -v shims <<< "$PATH" | tr ':' '\n' | while read p; do [ -x "$p/prettier" ] && { "$p/prettier" ...; break; }; done`
- Also note: `MISE_SKIP_CONFIG=1` skips tool-version config loading but does NOT bypass global config trust checks — the trust lookup uses `getpwuid()` for path resolution, not `$HOME` env var, so trust records may still fail with a changed `$HOME`.

## Conditional Final Statements

**FORBIDDEN: `[ condition ] && action` as final statement** — the one-liner flips the exit/return code when condition is false.

```bash
# WRONG: if VERBOSE unset, exits/returns non-zero
my_func() {
  do_work
  [ -n "${VERBOSE:-}" ] && printf 'debug'  # ← LAST LINE: flips rc
}

# CORRECT: if/then/fi + explicit return
my_func() {
  do_work
  if [ -n "${VERBOSE:-}" ]; then
    printf 'debug'
  fi
  return 0
}
```

The `&&` exits with the **condition's** result, not the action's. When condition fails (e.g., `VERBOSE` unset), the one-liner exits 1, breaking pass/fail accounting.

Safe only when followed by other statements. Use `if/then/fi` + explicit `return 0` or `exit 0` for last-statement conditionals. Applies to any `[ test ] && action` pattern as function/script final line.

## Test Output Control (VERBOSE Gating)

**Quiet-on-pass pattern with VERBOSE gating** — suppress verbose test output in normal runs, emit on demand:

```bash
if [ -n "${VERBOSE:-}" ]; then
    printf 'debug output'
fi
return 0
```

Scales across test files and is bash-3.2-compatible. Example: `if [ -n "${VERBOSE:-}" ]; then echo "Testing $file"; fi` emits only when `VERBOSE=1` is set, and does not flip the exit code.

## Grep -v Footgun (Substring Patterns)

**`grep -v "substring"` deletes ENTIRE lines containing the substring, not just dedicated keys/entries.** This is a footgun when the substring appears inside a larger data structure.

Example: `grep -v '"ecto\.'` on a JSON/EEx aliases block deletes any line containing a string element with `"ecto.` in it, not just ecto alias definition lines:

```bash
# Input: mix.exs aliases block
test: ["test", "ecto.create --quiet", "ecto.migrate", ...],
ci: ["format", "cmd npx prettier -c ."],

# WRONG: grep -v '"ecto\.' deletes the ENTIRE test: line
grep -v '"ecto\.' file  # → ci: line survives; test: line is gone (contains "ecto.create")

# CORRECT: explicit per-line transform
# 1. Process the line that must survive in transformed form (test: → ["test"])
# 2. Then drop remaining "ecto." lines
python3 << 'EOF'
import sys
for line in sys.stdin:
    if line.strip().startswith('test:'):
        sys.stdout.write('        test: ["test"],\n')  # rewrite
    elif '"ecto.' not in line:
        sys.stdout.write(line)  # pass-through non-ecto lines
EOF
```

**Key insight**: When a line must survive but in transformed form (rewrite), process it BEFORE the drop condition. When using Python transforms with two competing conditions on the same line, the first matching `continue` wins — order the conditions so rewrites execute before drops.

## Grep / Eval Quoting Pitfall

**`grep` assertions inside `eval` strings double-collapse backslashes at the shell boundary, corrupting regex escapes.** Inner double-quotes close the outer `eval` string, silently changing what is matched. When the condition string uses `-q "pattern"` with backslash escapes (e.g., `\.` for a literal dot), the eval re-parses the string and collapses `\.` to `.`, breaking the regex.

Example: asserting `test: ["test"]` inside eval:

```bash
# WRONG: inner double-quotes close the outer string
assert_condition='grep -qF "test: [\"test\"]"'
eval "$assert_condition file"
# → shell expands to: grep -qF test: [ (unquoted) file
# → matches wrong pattern or fails to parse

# WRONG: escape collapses under eval re-parse
assert_condition='grep -q "pattern\\.ext"'
eval "$assert_condition file"
# → first shell parse: grep -q "pattern\.ext"
# → eval re-parses: grep -q pattern.ext (no escape)
# → matches "pattern<any-char>ext", not "pattern.ext"

# CORRECT: single-quoted outer string + fixed-string grep -F
assert_condition='grep -qF "literal_token_with_dots.ext"'
eval "$assert_condition file"
# → -F treats pattern as literal; eval boundary is single-quoted, no re-parse

# ALSO CORRECT: single-quoted outer string + ERE-escaped pattern (for regex)
assert_condition='grep -q "test: \[\"test\"\]"'
eval "$assert_condition file"
# → shell expands to: grep -q "test: \[\"test\"\]" file
# → grep receives literal brackets + quotes intact
```

**Rule of thumb**: When passing `grep` assertions through `eval`:

1. Prefer `grep -F` (fixed-string) for literal token checks — avoids regex escaping confusion entirely.
2. If regex is needed, use single quotes for the outer string and ERE-escape `[`, `]`, `"` characters.
3. Verify by printing the eval statement before running it.

Pattern discovered in test-script `assert` helpers (e.g., `credo_live_strict_test.sh`) where `grep -q "pattern\\.token"` inside eval collapses to non-matching regex. Switching to `grep -qF` for fixed-string assertions eliminates the pitfall.

## Renderer-Neutral Regex Tokens in enforcement_compiler.py

**`enforcement_compiler.py` `_to_bash` does a literal `.replace(r"\s", "[[:space:]]")` — this fires inside character classes too, corrupting nested brackets.** When defining regex patterns in `shared/enforcement/registry.yaml` that will be compiled to both bash ERE and JavaScript regex, avoid `\s` inside char classes (`[^&\s]`, `[\s]`), as it will be transformed to `[^&[[:space:]]]` (broken nested bracket). The bash ERE and JS renders will diverge.

**Pattern**: Use `\S` or `\S+` (negated char classes that round-trip identically):

```bash
# WRONG — \s inside char class corrupts bash render
match: "[^&\s]+"  # → bash: [^&[[:space:]]]+ (broken); JS: /[^&\s]+/ (OK)

# CORRECT — \S round-trips both renderers identically
match: "[^&]*\\S+"  # → bash: [^&]*\S+; JS: /[^&]*\S+/
```

The token `\S` contains no literal `\s` substring and no `/`, so replacement logic does not fire on it in either renderer. This pattern ensures both generated `.sh` (bash ERE) and `.ts` (JavaScript regex) carry the same semantic intent without divergence from the compilation step.

Verification: test both `_to_bash` and `_to_ts` renderers on the pattern; they should produce identical output (mod language-specific escaping of backslashes in string literals).

## Hook Discovery Fallback Gating in Managed Builds

**Transcript-bound hooks with filesystem fallback must widen fallback gates to match any managed-build env var, not just platform-specific roots.** When a bash hook discovers resources (e.g., step-log files) via transcript JSONL parsing, the transcript may lag behind the live stream on slow-flushing Node runtimes (observed: Node 20 with flush delays). A fallback filesystem scan is essential, but **the fallback gate must match the actual managed-build condition** — not just `OCG_APPS_ROOT` (platform-specific root path) but also any build-mode flag that indicates a non-interactive managed execution.

**Pattern**:

```bash
# Strict transcript-bound discovery (interactive sessions)
result=$(jq -r '.[] | select(.type=="Write" and .path | test("codegen/logging")) | .path' "$TRANSCRIPT_PATH" | tail -1)

# Fallback 1: OCG_APPS_ROOT (managed workers on platform)
if [ -z "$result" ]; then
    local apps_root="${OCG_APPS_ROOT:-}"
    local cwd="${CWD:-$PWD}"
    if [ -n "$apps_root" ]; then
        case "$cwd" in
        "${apps_root%/}"/*)
            result=$(ls -t "$cwd/codegen/logging"/*.md 2>/dev/null | head -1)
            ;;
        esac
    fi
fi

# Fallback 2: CODEGEN_BUILD_NON_INTERACTIVE (non-interactive managed builds)
# This catches codegen self-builds and other non-interactive contexts where
# dispatch.sh or similar entrypoint sets the flag. Scan cwd unconditionally
# (cwd is already the app dir in managed builds); fail-closed if dir empty.
if [ -z "$result" ] && [ -n "${CODEGEN_BUILD_NON_INTERACTIVE:-}" ]; then
    result=$(ls -t "$cwd/codegen/logging"/*.md 2>/dev/null | head -1)
fi
```

**Why two branches**: `OCG_APPS_ROOT` is a platform convention (managed workers on the dashboard box); `CODEGEN_BUILD_NON_INTERACTIVE` is a build-mode convention (set by dispatch.sh for non-interactive entrypoints). They are independent gates that cover different deployment patterns.

**Mtime sorting portability**: Use `ls -t glob | head -1` across macOS (BSD find) and Linux (GNU coreutils). `find -printf` is not portable to BSD find and silently fails (no error, just empty output).

**Fail-closed semantics**: An empty or absent logging directory yields empty `result` — the caller denies the action. Test both the success path (fallback fires, returns a valid path) and the fail-closed path (empty dir, returns empty) to prevent false-positive phantom paths.
