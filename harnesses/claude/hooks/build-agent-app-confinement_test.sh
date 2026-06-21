#!/bin/bash
# build-agent-app-confinement_test.sh — unit tests for build-agent-app-confinement.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/build-agent-app-confinement.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2" # "deny" or "allow"
    local input="$3"
    local extra_env="${4:-}"

    local stdout
    if [ -n "$extra_env" ]; then
        stdout=$(printf '%s' "$input" | env $extra_env bash "$HOOK" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | bash "$HOOK" 2>/dev/null || true)
    fi

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="deny"
    else
        outcome="allow"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

make_input() {
    local tool="$1"
    local file_path="$2"
    local cwd="${3:-$PWD}"
    jq -n \
        --arg tool "$tool" \
        --arg fp "$file_path" \
        --arg cwd "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":$tool,"tool_input":{"file_path":$fp},"agent_type":"developer-phoenix-backend","agent_id":"abc","cwd":$cwd}'
}

# Create a real temp dir to use as the sandbox.
SANDBOX="$(mktemp -d)"
OUTSIDE="$(mktemp -d)"
trap 'rm -rf "$SANDBOX" "$OUTSIDE"' EXIT

SANDBOX_FILE="$SANDBOX/lib/foo.ex"
mkdir -p "$(dirname "$SANDBOX_FILE")"
touch "$SANDBOX_FILE"

OUTSIDE_FILE="$OUTSIDE/secrets.txt"
touch "$OUTSIDE_FILE"

# ── Test 1: CODEGEN_BUILD_CWD unset → Write outside sandbox → ALLOW (inert) ──
INPUT_T1=$(make_input "Write" "$OUTSIDE_FILE" "$SANDBOX")
stdout_t1=$(printf '%s' "$INPUT_T1" | env -u CODEGEN_BUILD_CWD bash "$HOOK" 2>/dev/null || true)
outcome_t1="allow"
if printf '%s' "$stdout_t1" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    outcome_t1="deny"
fi
if [ "$outcome_t1" = "allow" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: CODEGEN_BUILD_CWD unset → Write outside sandbox → ALLOW\n'
    pass=$((pass + 1))
else
    printf 'FAIL: CODEGEN_BUILD_CWD unset → Write outside sandbox — expected allow, got %s\n  stdout: %s\n' "$outcome_t1" "$stdout_t1"
    fail=$((fail + 1))
fi

# ── Test 2: CODEGEN_BUILD_CWD set, file inside sandbox → ALLOW ────────────────
INPUT_T2=$(make_input "Write" "$SANDBOX_FILE" "$SANDBOX")
run_test "Write inside sandbox → ALLOW" "allow" "$INPUT_T2" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 3: CODEGEN_BUILD_CWD set, file outside sandbox → DENY ───────────────
INPUT_T3=$(make_input "Write" "$OUTSIDE_FILE" "$SANDBOX")
run_test "Write outside sandbox → DENY" "deny" "$INPUT_T3" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 4: /tmp escape hatch → ALLOW even with CODEGEN_BUILD_CWD set ────────
INPUT_T4=$(make_input "Write" "/tmp/scratch.txt" "$SANDBOX")
run_test "/tmp escape hatch → ALLOW" "allow" "$INPUT_T4" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 5: /private/tmp escape hatch (macOS symlink) → ALLOW ─────────────────
INPUT_T5=$(make_input "Write" "/private/tmp/scratch.txt" "$SANDBOX")
run_test "/private/tmp escape hatch → ALLOW" "allow" "$INPUT_T5" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 6: sibling-dir prefix must not be false-allowed ──────────────────────
# /apps/app must not match /apps/app2
SIBLING_DIR="${OUTSIDE}/sibling"
mkdir -p "$SIBLING_DIR"
SIBLING_FILE="$SIBLING_DIR/file.txt"
touch "$SIBLING_FILE"
# Create a sandbox whose name is a prefix of sibling dir name
SIBLING_SANDBOX="${OUTSIDE}/sib"
mkdir -p "$SIBLING_SANDBOX"
# SANDBOX name = /tmp/.../sib — sibling = /tmp/.../sibling (has same prefix)
INPUT_T6=$(make_input "Write" "$SIBLING_FILE" "$SIBLING_SANDBOX")
run_test "sibling-dir prefix false-allow blocked → DENY" "deny" "$INPUT_T6" "CODEGEN_BUILD_CWD=$SIBLING_SANDBOX"

# ── Test 7: Edit tool outside sandbox → DENY ─────────────────────────────────
INPUT_T7=$(make_input "Edit" "$OUTSIDE_FILE" "$SANDBOX")
run_test "Edit outside sandbox → DENY" "deny" "$INPUT_T7" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 8: MultiEdit tool outside sandbox → DENY ─────────────────────────────
# MultiEdit uses same file_path field in hook payload
INPUT_T8=$(make_input "MultiEdit" "$OUTSIDE_FILE" "$SANDBOX")
run_test "MultiEdit outside sandbox → DENY" "deny" "$INPUT_T8" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 9: relative path resolves inside sandbox → ALLOW ─────────────────────
# hooks_realpath resolves relative paths against $PWD — so we run with
# the sandbox as cwd via env; hook's $PWD will be $SANDBOX during test.
# We pass a relative path that stays inside.
REL_INPUT=$(jq -n \
    --arg cwd "$SANDBOX" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"lib/new.ex"},"agent_type":"developer-phoenix-backend","agent_id":"abc","cwd":$cwd}')
stdout_t9=$(cd "$SANDBOX" && printf '%s' "$REL_INPUT" | CODEGEN_BUILD_CWD="$SANDBOX" bash "$HOOK" 2>/dev/null || true)
outcome_t9="allow"
if printf '%s' "$stdout_t9" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    outcome_t9="deny"
fi
if [ "$outcome_t9" = "allow" ]; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: relative path inside sandbox → ALLOW\n'
    pass=$((pass + 1))
else
    printf 'FAIL: relative path inside sandbox → expected allow, got %s\n  stdout: %s\n' "$outcome_t9" "$stdout_t9"
    fail=$((fail + 1))
fi

# ── Test 10: empty FILE_PATH → ALLOW (no path to evaluate) ────────────────────
EMPTY_PATH_INPUT=$(jq -n \
    --arg cwd "$SANDBOX" \
    '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":""},"agent_type":"developer-phoenix-backend","agent_id":"abc","cwd":$cwd}')
run_test "empty FILE_PATH → ALLOW (no-op)" "allow" "$EMPTY_PATH_INPUT" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 11: CODEGEN_BUILD_CWD set to empty string → ALLOW (inert) ────────────
INPUT_T11=$(make_input "Write" "$OUTSIDE_FILE" "$SANDBOX")
run_test "CODEGEN_BUILD_CWD empty string → ALLOW" "allow" "$INPUT_T11" "CODEGEN_BUILD_CWD="

# ── Test 12: path equal to sandbox root itself → ALLOW ─────────────────────────
INPUT_T12=$(make_input "Write" "$SANDBOX" "$SANDBOX")
run_test "file path == sandbox root → ALLOW" "allow" "$INPUT_T12" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 13: deeply nested file inside sandbox → ALLOW ─────────────────────────
DEEP_FILE="$SANDBOX/a/b/c/d/deep.ex"
mkdir -p "$(dirname "$DEEP_FILE")"
touch "$DEEP_FILE"
INPUT_T13=$(make_input "Write" "$DEEP_FILE" "$SANDBOX")
run_test "deeply nested file inside sandbox → ALLOW" "allow" "$INPUT_T13" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 14: symlink inside sandbox resolving outside → DENY ──────────────────
# Create a symlink inside SANDBOX that points to OUTSIDE_FILE.
SYMLINK_PATH="$SANDBOX/escape_link"
ln -sf "$OUTSIDE_FILE" "$SYMLINK_PATH"
INPUT_T14=$(make_input "Write" "$SYMLINK_PATH" "$SANDBOX")
run_test "symlink inside sandbox resolving outside → DENY" "deny" "$INPUT_T14" "CODEGEN_BUILD_CWD=$SANDBOX"

# ── Test 15: non-write tool (Read) with CODEGEN_BUILD_CWD set → ALLOW ─────────
READ_INPUT=$(jq -n \
    --arg cwd "$SANDBOX" \
    --arg fp "$OUTSIDE_FILE" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":$fp},"agent_type":"developer-phoenix-backend","agent_id":"abc","cwd":$cwd}')
run_test "Read tool (not in scope) → ALLOW" "allow" "$READ_INPUT" "CODEGEN_BUILD_CWD=$SANDBOX"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
