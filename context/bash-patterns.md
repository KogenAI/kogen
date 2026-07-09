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

Bash hook `_test.sh` files run directly (not via `run-tests.sh`) inherit ambient shell env vars. If the developer's own agent shell sets `CLAUDE_ROLE` or `PI_ROLE`, direct test invocations see the leakage and may hit unintended code paths. Example: Test 45 in `orchestrator-no-source-edit_test.sh` uses `run_test` (not `run_test_role`), so it reads the ambient env directly; if `CLAUDE_ROLE=build` is set, the test wrongly selects the build-role path and fails for an unrelated reason.

**Fix**: When running hook `_test.sh` files interactively (outside the CI clean shell), strip inherited role vars before invocation:

```bash
env -u CLAUDE_ROLE -u PI_ROLE bash <test>.sh
```

This is NOT needed when tests run via `harnesses/claude/hooks/run-tests.sh` in a clean CI environment — only when invoking directly from within an agent session. The issue is test-invocation discipline (direct runs), not the tests themselves (run-tests.sh context cleans the env).

## git show Redirect Source-Sourcing Trap

When creating a RED-then-GREEN proof by redirecting a hook script via `git show HEAD:<path> > /tmp/copy.sh`, the copied script may use relative sourcing (e.g., `source "$(dirname "$0")/lib/hooks-lib.sh"`). The `dirname` of `/tmp/copy.sh` is `/tmp/`, not the original source directory, so the relative path breaks and the sourced file is not found.

**Fix**: Perform RED-then-GREEN swaps IN-PLACE rather than copying the hook to a temp location:

1. Save the original: `git show HEAD:<hook.sh> > /tmp/pre-fix.sh`
2. Swap in the pre-fix: `cp /tmp/pre-fix.sh <real-hook-path>`
3. Run the test (RED phase): verify it fails/blocks as expected
4. Restore from a backup of the post-fix version or re-edit in-place
5. Run the test again (GREEN phase): verify it passes

This keeps both `dirname "$0"` resolutions in the real source directory where relative sourcing works correctly.

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
- **[shared] RED-then-GREEN proof via floating `git show HEAD:<file>` self-invalidates once fix lands** — When a proof depends on `git show HEAD:<file>` to pull pre-fix "broken" state, the moment the fix commits to HEAD the proof self-invalidates. Fix: synthesize hardcoded pre-fix fixture reproducing exact historical bug instead of relying on floating HEAD state.
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

## Trigger Keywords

stateful stub, counter file, test isolation, RED-then-GREEN proof, bash test patterns, ambient env leakage, CLAUDE_ROLE, PI_ROLE, git show, dirname sourcing, PIPESTATUS, jq null safety, yq null safety, portable sed, macOS symlink, grep footguns, PATH stub, hook deletion full-vocabulary grep, run-tests.sh not a registered hook, zsh completion bash -n misparse
