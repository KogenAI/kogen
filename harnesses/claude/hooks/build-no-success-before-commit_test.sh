#!/bin/bash
# build-no-success-before-commit_test.sh — unit tests for build-no-success-before-commit.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/build-no-success-before-commit.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_project() {
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir"
        git init -q
        git config user.email t@t
        git config user.name t
        git checkout -q -b main
        echo init >README
        git add README
        git commit -qm init
    )
    printf '%s' "$dir"
}

make_input() {
    local cmd="$1"
    local cwd="${2:-$PWD}"
    jq -n \
        --arg cmd "$cmd" \
        --arg cwd "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":"","agent_id":"abc","cwd":$cwd}'
}

# ── Test 1: no BUILD_RESULT: in command → ALLOW ──────────────────────────────
T1=$(make_project)
out=$(make_input "echo hello" "$T1" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "no BUILD_RESULT: → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T1"

# ── Test 2: COMBOBULATE_BUILD_START_TS unset → ALLOW ────────────────────────
T2=$(make_project)
out=$(make_input 'echo "BUILD_RESULT: success"' "$T2" | env -u COMBOBULATE_BUILD_START_TS bash "$HOOK" 2>/dev/null || true)
assert_not_contains "BUILD_START_TS unset → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T2"

# ── Test 3: BUILD_START_TS set, no commit since → BLOCK ─────────────────────
T3=$(make_project)
# Set timestamp to now (after the init commit)
ts3=$(date -u +%s)
out=$(make_input 'echo "BUILD_RESULT: success"' "$T3" | COMBOBULATE_BUILD_START_TS="$ts3" bash "$HOOK" 2>/dev/null || true)
assert_contains "BUILD_START_TS set, no new commit → BLOCK" '"permissionDecision"' "$out"
assert_contains "BLOCK reason mentions commit" 'git commit' "$out"
rm -rf "$T3"

# ── Test 4: BUILD_START_TS set, commit made after ts, gate-result clear → ALLOW ─
T4=$(make_project)
ts4=$(date -u +%s)
# Small sleep to ensure commit is after ts4
sleep 1
(
    cd "$T4"
    echo change >README
    git add README
    git commit -qm "generated code"
)
# Write a gate-result.json with verdict=clear so the hook's gate check passes
mkdir -p "$T4/codegen/gate-pending"
printf '{"verdict":"clear","gate":"make ci","exit_code":0}\n' >"$T4/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T4" | COMBOBULATE_BUILD_START_TS="$ts4" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "commit after BUILD_START_TS → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T4"

# ── Test 5: non-Bash tool → ALLOW ────────────────────────────────────────────
T5=$(make_project)
ts5=$(date -u +%s)
input5=$(jq -n \
    --arg cmd 'BUILD_RESULT: foo' \
    --arg cwd "$T5" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/foo"},"agent_type":"","agent_id":"abc","cwd":$cwd}')
out=$(printf '%s' "$input5" | COMBOBULATE_BUILD_START_TS="$ts5" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-Bash tool → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T5"

# ── Test 6: BUILD_RESULT: embedded in longer command → matched ───────────────
T6=$(make_project)
ts6=$(date -u +%s)
out=$(make_input 'printf "BUILD_RESULT: %s\n" success' "$T6" | COMBOBULATE_BUILD_START_TS="$ts6" bash "$HOOK" 2>/dev/null || true)
assert_contains "BUILD_RESULT: in longer command → BLOCK (no commit)" '"permissionDecision"' "$out"
rm -rf "$T6"

# ── Test 7: commit after ts + gate clear + dirty tree → BLOCK ────────────────
T7=$(make_project)
ts7=$(date -u +%s)
sleep 1
(
    cd "$T7"
    echo change >README
    git add README
    git commit -qm "generated code"
)
mkdir -p "$T7/codegen/gate-pending"
printf '{"verdict":"clear","gate":"make ci","exit_code":0}\n' >"$T7/codegen/gate-pending/gate-result.json"
# Create a dirty (uncommitted) file AFTER the commit
echo "dirty content" >"$T7/dirty.txt"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T7" | COMBOBULATE_BUILD_START_TS="$ts7" bash "$HOOK" 2>/dev/null || true)
assert_contains "dirty tree after commit+gate → BLOCK (permissionDecision)" '"permissionDecision"' "$out"
assert_contains "dirty tree block message mentions working tree" 'working tree not clean' "$out"
rm -rf "$T7"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
