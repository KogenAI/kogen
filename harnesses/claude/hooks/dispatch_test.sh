#!/usr/bin/env bash
# dispatch_test.sh — hermetic unit tests for harnesses/claude/dispatch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
DISPATCH="$SCRIPT_DIR/../dispatch.sh"

pass=0
fail=0

assert_eq() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle:   %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack:  %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# ── Shared temp dir — cleaned on EXIT ────────────────────────────────────────
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fake claude stub: print all env vars then exit 0
FAKE_BIN="$TMP_ROOT/bin"
mkdir -p "$FAKE_BIN"
printf '#!/usr/bin/env bash\nenv\nexit 0\n' >"$FAKE_BIN/claude"
chmod +x "$FAKE_BIN/claude"

# Passing codegen-log stub — dispatch.sh now preflights `codegen-log --version`
# before spawning any role. Without this stub, EVERY pre-existing exec-path
# case below would break (codegen-log absent from PATH -> preflight abort).
printf '#!/usr/bin/env bash\nprintf "codegen-log root=resolved\\n"\nexit 0\n' >"$FAKE_BIN/codegen-log"
chmod +x "$FAKE_BIN/codegen-log"

# Fake build-tools.txt in a scratch SCRIPT_DIR copy
FAKE_HARNESS="$TMP_ROOT/harness"
mkdir -p "$FAKE_HARNESS"
printf 'Agent\nBash\nEdit\n' >"$FAKE_HARNESS/build-tools.txt"
# Copy dispatch.sh into the fake harness dir so SCRIPT_DIR resolves correctly
cp "$DISPATCH" "$FAKE_HARNESS/dispatch.sh"
chmod +x "$FAKE_HARNESS/dispatch.sh"

# Fixture config dir: mirrors templates/generator/config.yaml structure
FAKE_CODEGEN="$TMP_ROOT/codegen"
mkdir -p "$FAKE_CODEGEN/templates/generator"
cat >"$FAKE_CODEGEN/templates/generator/config.yaml" <<'YAML'
harness:
  build:
    claude: { model: test-model, effort: low }
YAML

# Helper: run dispatch.sh with a minimal valid environment
# Args: env_overrides (as "KEY=VALUE ..."), extra positional args for dispatch.sh
run_dispatch() {
    local env_str="$1"
    shift
    local extra_args=("$@")

    # shellcheck disable=SC2086
    local _rc=0
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        CODEGEN_BUILD_ELIXIR=1 \
        $env_str \
        bash "$FAKE_HARNESS/dispatch.sh" \
        "${extra_args[@]+"${extra_args[@]}"}" \
        2>&1 || _rc=$?
    return "$_rc"
}

# ── Test 1: missing SP_FILE → exit 2 + "system prompt file not found" ────────
# No claude-build-system-prompt.txt in FAKE_HARNESS → guard fires
rc=0
out=$(run_dispatch "CODEGEN_BUILD_MODEL=test-model CODEGEN_BUILD_EFFORT=low" "dummy-prompt") || rc=$?
assert_contains "missing SP_FILE: stderr mentions 'system prompt file not found'" \
    "system prompt file not found" "$out"
assert_eq "missing SP_FILE: exit code 2" "2" "$rc"

# ── Test 2: valid SP_FILE + config + no test_harness/ dir → exit 2 ──────────
# Engine selected by CODEGEN_BUILD_ELIXIR (via run_dispatch helper) — the
# --elixir/no-resume path execs `mix codegen.loop`, which requires
# $CODEGEN_DIR/test_harness to exist. FAKE_CODEGEN has no test_harness/ dir,
# so dispatch must fail loud rather than silently fall through to the
# legacy claude stub path.
printf 'fake system prompt\n' >"$FAKE_HARNESS/claude-build-system-prompt.txt"
rc=0
out=$(run_dispatch "CODEGEN_BUILD_MODEL=test-model CODEGEN_BUILD_EFFORT=low CODEGEN_BUILD_STACK=phoenix" "dummy-prompt") || rc=$?
assert_eq "missing test_harness/ dir: exit code 2" "2" "$rc"
assert_contains "missing test_harness/ dir: stderr mentions 'orchestration loop dir not found'" \
    "orchestration loop dir not found" "$out"

# ── Test 2b: valid SP_FILE + config + fake mix + test_harness/ dir → loop execs ──
FAKE_BIN_MIX="$TMP_ROOT/bin-mix"
mkdir -p "$FAKE_BIN_MIX"
cp "$FAKE_BIN/claude" "$FAKE_BIN_MIX/claude"
cp "$FAKE_BIN/codegen-log" "$FAKE_BIN_MIX/codegen-log"
MIX_ARGS_FILE="$TMP_ROOT/mix-args.txt"
cat >"$FAKE_BIN_MIX/mix" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$MIX_ARGS_FILE"
env >>"$MIX_ARGS_FILE"
exit 0
STUB
chmod +x "$FAKE_BIN_MIX/mix"
mkdir -p "$FAKE_CODEGEN/test_harness"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_MODEL=test-model \
        CODEGEN_BUILD_EFFORT=low \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        CODEGEN_BUILD_ELIXIR=1 \
        CODEGEN_BUILD_STACK=phoenix \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "loop path: exit 0 (mix stub)" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    MIX_ARGS_CONTENT="$(cat "$MIX_ARGS_FILE")"
    assert_contains "loop path: mix codegen.loop invoked" "codegen.loop" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: --harness=claude_code passed" "--harness=claude_code" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: --stack passed" "--stack=" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: --cwd passed" "--cwd=" "$MIX_ARGS_CONTENT"
    assert_contains "loop path: prompt forwarded" "dummy-prompt" "$MIX_ARGS_CONTENT"
else
    printf 'FAIL: loop path — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 3: yq absent from PATH → exit 2 + "yq not found" ───────────────────
# Build a fake bin with claude but WITHOUT yq; unset MODEL+EFFORT so config path is taken
FAKE_BIN_NOYQ="$TMP_ROOT/bin-noyq"
mkdir -p "$FAKE_BIN_NOYQ"
cp "$FAKE_BIN/claude" "$FAKE_BIN_NOYQ/claude"
cp "$FAKE_BIN/codegen-log" "$FAKE_BIN_NOYQ/codegen-log"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_NOYQ:/usr/bin:/bin" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_contains "yq absent: stderr mentions 'yq not found on PATH'" \
    "yq not found on PATH" "$out"
assert_eq "yq absent: exit code should be 2" "2" "$rc"

# ── Test 4: malformed config.yaml → exit 2 + "failed to parse config.yaml" ───
FAKE_CODEGEN_BAD="$TMP_ROOT/codegen-bad"
mkdir -p "$FAKE_CODEGEN_BAD/templates/generator"
printf 'a: [unterminated\n' >"$FAKE_CODEGEN_BAD/templates/generator/config.yaml"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_BAD" \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_contains "malformed config: stderr mentions 'failed to parse config.yaml'" \
    "failed to parse config.yaml" "$out"
assert_eq "malformed config: exit code should be 2" "2" "$rc"

# ── Test 5: absent harness.build.claude.model key → exit 1 + "model missing/empty" ──
# Regression-lock the pre-existing check (yq returns "null" for absent key)
FAKE_CODEGEN_NOMODEL="$TMP_ROOT/codegen-nomodel"
mkdir -p "$FAKE_CODEGEN_NOMODEL/templates/generator"
cat >"$FAKE_CODEGEN_NOMODEL/templates/generator/config.yaml" <<'YAML'
harness:
  build:
    claude: { effort: low }
YAML
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN_NOMODEL" \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_contains "missing model key: stderr mentions 'model missing/empty'" \
    "model missing/empty" "$out"
assert_eq "missing model key: exit code should be 1" "1" "$rc"

# ── Test 6: env-isolation — provider keys stripped before exec (loop path) ────
# Caller passes OPENAI_API_KEY + ANTHROPIC_API_KEY; mix stub prints env.
# Assertions: keys NOT in captured env; CODEGEN_DIR IS (positive control —
# proves the loop's own exec env, not the old exec block, ran).
rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_MODEL=test-model \
        CODEGEN_BUILD_EFFORT=low \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        CODEGEN_BUILD_ELIXIR=1 \
        CODEGEN_BUILD_STACK=phoenix \
        OPENAI_API_KEY=leak1 \
        ANTHROPIC_API_KEY=leak2 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "env-isolation: loop path exit 0" "0" "$rc"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    ENV_OUT="$(cat "$MIX_ARGS_FILE")"
    assert_not_contains "env-isolation: OPENAI_API_KEY not in loop exec env" \
        "OPENAI_API_KEY" "$ENV_OUT"
    assert_not_contains "env-isolation: ANTHROPIC_API_KEY not in loop exec env" \
        "ANTHROPIC_API_KEY" "$ENV_OUT"
    assert_contains "env-isolation: CODEGEN_DIR present (positive control — mix stub ran)" \
        "CODEGEN_DIR=" "$ENV_OUT"
else
    printf 'FAIL: env-isolation — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 7: engine=elixir banner — CODEGEN_BUILD_ELIXIR=1 selects loop, mix stub runs ──
rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_MODEL=test-model \
        CODEGEN_BUILD_EFFORT=low \
        CODEGEN_BUILD_ELIXIR=1 \
        CODEGEN_BUILD_STACK=phoenix \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "engine=elixir: exit 0 (mix stub)" "0" "$rc"
assert_contains "engine=elixir: banner present" "claude dispatch: engine=elixir" "$out"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    assert_contains "engine=elixir: mix codegen.loop invoked" "codegen.loop" "$(cat "$MIX_ARGS_FILE")"
else
    printf 'FAIL: engine=elixir — mix args file missing\n'
    fail=$((fail + 1))
fi

# ── Test 8: engine=legacy banner — CODEGEN_BUILD_ELIXIR unset, NON_INTERACTIVE=1 → claude runs, mix does NOT ──
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_MODEL=test-model \
        CODEGEN_BUILD_EFFORT=low \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "engine=legacy: exit 0 (claude stub)" "0" "$rc"
assert_contains "engine=legacy: banner present" "claude dispatch: engine=legacy" "$out"
assert_not_contains "engine=legacy: engine=elixir banner absent" "claude dispatch: engine=elixir" "$out"

# ── Test 9: CODEGEN_BUILD_STACK unset/empty in --elixir path → exit 2 + clear message ──
# Regression lock: dispatch.sh must NOT silently coerce an empty/unset stack
# to "phoenix" — it must fail loud naming CODEGEN_BUILD_STACK.
rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_MIX:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_MODEL=test-model \
        CODEGEN_BUILD_EFFORT=low \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        CODEGEN_BUILD_ELIXIR=1 \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "missing CODEGEN_BUILD_STACK: exit code 2" "2" "$rc"
assert_contains "missing CODEGEN_BUILD_STACK: stderr names CODEGEN_BUILD_STACK" \
    "CODEGEN_BUILD_STACK is required but empty/unset" "$out"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    printf 'FAIL: missing CODEGEN_BUILD_STACK — mix must NOT have been invoked\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: missing CODEGEN_BUILD_STACK — mix not invoked\n'
    pass=$((pass + 1))
fi

# ── Test 10: codegen-log preflight — broken/absent codegen-log aborts loud,
# before any role spawns (assert exec-not-reached via the mix-args-file
# shimmed-subprocess marker, same pattern used by Test 9). ─────────────────
FAKE_BIN_BROKEN_LOG="$TMP_ROOT/bin-broken-log"
mkdir -p "$FAKE_BIN_BROKEN_LOG"
cp "$FAKE_BIN/claude" "$FAKE_BIN_BROKEN_LOG/claude"
cp "$FAKE_BIN_MIX/mix" "$FAKE_BIN_BROKEN_LOG/mix"
printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKE_BIN_BROKEN_LOG/codegen-log"
chmod +x "$FAKE_BIN_BROKEN_LOG/codegen-log"

rm -f "$MIX_ARGS_FILE"
rc=0
out=$(
    env -i \
        HOME="${HOME:-/tmp}" \
        PATH="$FAKE_BIN_BROKEN_LOG:$PATH" \
        OCG_CODEGEN_DIR="$FAKE_CODEGEN" \
        CODEGEN_BUILD_MODEL=test-model \
        CODEGEN_BUILD_EFFORT=low \
        CODEGEN_BUILD_NON_INTERACTIVE=1 \
        CODEGEN_BUILD_ELIXIR=1 \
        CODEGEN_BUILD_STACK=phoenix \
        bash "$FAKE_HARNESS/dispatch.sh" "dummy-prompt" \
        2>&1
) || rc=$?
assert_eq "broken codegen-log: exit code non-zero (2)" "2" "$rc"
assert_contains "broken codegen-log: stderr names codegen-log unresolvable" \
    "codegen-log unresolvable" "$out"
assert_contains "broken codegen-log: stderr suggests make install" \
    "make install" "$out"
if [[ -f "$MIX_ARGS_FILE" ]]; then
    printf 'FAIL: broken codegen-log — mix must NOT have been invoked (preflight must abort before exec)\n'
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: broken codegen-log — mix not invoked (aborted before exec)\n'
    pass=$((pass + 1))
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
