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
