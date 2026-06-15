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
        # Ignore gate-pending dir — mirrors real project .gitignore so gate-result.json
        # does not pollute the dirty-tree check in tests that expect ALLOW.
        printf 'codegen/gate-pending/\n' >.gitignore
        git add README .gitignore
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

# ── Test 2: CODEGEN_BUILD_START_TS unset → ALLOW ────────────────────────
T2=$(make_project)
out=$(make_input 'echo "BUILD_RESULT: success"' "$T2" | env -u CODEGEN_BUILD_START_TS bash "$HOOK" 2>/dev/null || true)
assert_not_contains "BUILD_START_TS unset → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T2"

# ── Test 3: BUILD_START_TS set, no commit since → BLOCK ─────────────────────
T3=$(make_project)
# Set timestamp to now (after the init commit)
ts3=$(date -u +%s)
out=$(make_input 'echo "BUILD_RESULT: success"' "$T3" | CODEGEN_BUILD_START_TS="$ts3" bash "$HOOK" 2>/dev/null || true)
assert_contains "BUILD_START_TS set, no new commit → BLOCK" '"permissionDecision"' "$out"
assert_contains "BLOCK reason mentions commit" 'git commit' "$out"
rm -rf "$T3"

# ── Test 4: BUILD_START_TS set, commit made after ts, gate-result clear + matching diff_sha → ALLOW ─
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
# Write a gate-result.json with verdict=clear and diff_sha matching current HEAD
head4=$(git -C "$T4" rev-parse --short HEAD)
mkdir -p "$T4/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head4" >"$T4/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T4" | CODEGEN_BUILD_START_TS="$ts4" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "commit after BUILD_START_TS + matching diff_sha → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T4"

# ── Test 5: non-Bash tool → ALLOW ────────────────────────────────────────────
T5=$(make_project)
ts5=$(date -u +%s)
input5=$(jq -n \
    --arg cmd 'BUILD_RESULT: foo' \
    --arg cwd "$T5" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/foo"},"agent_type":"","agent_id":"abc","cwd":$cwd}')
out=$(printf '%s' "$input5" | CODEGEN_BUILD_START_TS="$ts5" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-Bash tool → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T5"

# ── Test 6: BUILD_RESULT: embedded in longer command → matched ───────────────
T6=$(make_project)
ts6=$(date -u +%s)
out=$(make_input 'printf "BUILD_RESULT: %s\n" success' "$T6" | CODEGEN_BUILD_START_TS="$ts6" bash "$HOOK" 2>/dev/null || true)
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
head7=$(git -C "$T7" rev-parse --short HEAD)
mkdir -p "$T7/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head7" >"$T7/codegen/gate-pending/gate-result.json"
# Create a dirty (uncommitted) file AFTER the commit
echo "dirty content" >"$T7/dirty.txt"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T7" | CODEGEN_BUILD_START_TS="$ts7" bash "$HOOK" 2>/dev/null || true)
assert_contains "dirty tree after commit+gate → BLOCK (permissionDecision)" '"permissionDecision"' "$out"
assert_contains "dirty tree block message mentions working tree" 'working tree not clean' "$out"
rm -rf "$T7"

# ── Test 8: gate-result.json diff_sha does not match HEAD → BLOCK ────────────
T8=$(make_project)
ts8=$(date -u +%s)
sleep 1
(
    cd "$T8"
    echo change >README
    git add README
    git commit -qm "generated code"
)
mkdir -p "$T8/codegen/gate-pending"
# Write gate-result.json with a stale (wrong) diff_sha
printf '{"verdict":"clear","diff_sha":"abc1234","gate":"make ci","exit_code":0}\n' >"$T8/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T8" | CODEGEN_BUILD_START_TS="$ts8" bash "$HOOK" 2>/dev/null || true)
assert_contains "stale diff_sha → BLOCK (permissionDecision)" '"permissionDecision"' "$out"
assert_contains "stale diff_sha block message mentions stale SHA" 'stale SHA' "$out"
rm -rf "$T8"

# ── Test 9: gate-result.json verdict=clear with no diff_sha field → ALLOW ────
# (gate result written by older version without diff_sha — SHA check skipped gracefully)
T9=$(make_project)
ts9=$(date -u +%s)
sleep 1
(
    cd "$T9"
    echo change >README
    git add README
    git commit -qm "generated code"
)
mkdir -p "$T9/codegen/gate-pending"
# Omit diff_sha entirely — older gate-result format
printf '{"verdict":"clear","gate":"make ci","exit_code":0}\n' >"$T9/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T9" | CODEGEN_BUILD_START_TS="$ts9" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "no diff_sha field → SHA check skipped → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T9"

# Helper: make a second git repo (simulates OCG repo)
make_ocg_repo() {
    local dir
    dir=$(mktemp -d)
    (
        cd "$dir"
        git init -q
        git config user.email t@t
        git config user.name t
        git checkout -q -b main
        echo ocg >README
        git add README
        git commit -qm "ocg-init"
    )
    printf '%s' "$dir"
}

# ── Test 10: distinct OCG repo with dirty file → BLOCK ───────────────────────
T10_PROJECT=$(make_project)
T10_OCG=$(make_ocg_repo)
ts10=$(date -u +%s)
sleep 1
# Commit the symlink before the generated-code commit so the tree stays clean
(
    cd "$T10_PROJECT"
    mkdir -p codegen
    ln -s "$T10_OCG" codegen/rules
    git add codegen/rules
    git commit -qm "add rules symlink"
    echo change >README
    git add README
    git commit -qm "generated code"
)
head10=$(git -C "$T10_PROJECT" rev-parse --short HEAD)
mkdir -p "$T10_PROJECT/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head10" >"$T10_PROJECT/codegen/gate-pending/gate-result.json"
# Make OCG repo dirty after project commits
echo "dirty" >"$T10_OCG/dirty.txt"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T10_PROJECT" | CODEGEN_BUILD_START_TS="$ts10" bash "$HOOK" 2>/dev/null || true)
assert_contains "distinct OCG repo with dirty file → BLOCK" '"permissionDecision"' "$out"
assert_contains "BLOCK reason mentions OCG repo" 'OCG repo has uncommitted changes' "$out"
rm -rf "$T10_PROJECT" "$T10_OCG"

# ── Test 11: distinct OCG repo, clean → ALLOW ────────────────────────────────
T11_PROJECT=$(make_project)
T11_OCG=$(make_ocg_repo)
ts11=$(date -u +%s)
sleep 1
(
    cd "$T11_PROJECT"
    mkdir -p codegen
    ln -s "$T11_OCG" codegen/rules
    git add codegen/rules
    git commit -qm "add rules symlink"
    echo change >README
    git add README
    git commit -qm "generated code"
)
head11=$(git -C "$T11_PROJECT" rev-parse --short HEAD)
mkdir -p "$T11_PROJECT/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head11" >"$T11_PROJECT/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T11_PROJECT" | CODEGEN_BUILD_START_TS="$ts11" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "distinct OCG repo clean → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T11_PROJECT" "$T11_OCG"

# ── Test 12: OCG root == project root (codegen-on-codegen) → ALLOW ───────────
T12=$(make_project)
ts12=$(date -u +%s)
sleep 1
(
    cd "$T12"
    # Symlink inside the same repo; commit it so tree stays clean
    mkdir -p shared/rules
    ln -s "$T12/shared/rules" codegen/rules 2>/dev/null || ln -s shared/rules codegen/rules
    git add codegen/rules
    git commit -qm "add rules symlink (same repo)"
    echo change >README
    git add README
    git commit -qm "generated code"
)
head12=$(git -C "$T12" rev-parse --short HEAD)
mkdir -p "$T12/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head12" >"$T12/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T12" | CODEGEN_BUILD_START_TS="$ts12" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "OCG root == project root → ALLOW (skip second check)" '"permissionDecision"' "$out"
rm -rf "$T12"

# ── Test 13: codegen/rules is not a symlink → ALLOW (fail-open) ──────────────
T13=$(make_project)
ts13=$(date -u +%s)
sleep 1
(
    cd "$T13"
    # Create codegen/rules as a plain directory (not a symlink); commit it
    mkdir -p codegen/rules
    touch codegen/rules/.keep
    git add codegen/rules
    git commit -qm "add rules dir (not symlink)"
    echo change >README
    git add README
    git commit -qm "generated code"
)
head13=$(git -C "$T13" rev-parse --short HEAD)
mkdir -p "$T13/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head13" >"$T13/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T13" | CODEGEN_BUILD_START_TS="$ts13" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "codegen/rules not a symlink → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T13"

# ── Test 14: symlink target is not a git repo → ALLOW (fail-open) ────────────
T14_PROJECT=$(make_project)
T14_NONGIT=$(mktemp -d)
ts14=$(date -u +%s)
sleep 1
(
    cd "$T14_PROJECT"
    mkdir -p codegen
    ln -s "$T14_NONGIT" codegen/rules
    git add codegen/rules
    git commit -qm "add rules symlink to non-git dir"
    echo change >README
    git add README
    git commit -qm "generated code"
)
head14=$(git -C "$T14_PROJECT" rev-parse --short HEAD)
mkdir -p "$T14_PROJECT/codegen/gate-pending"
printf '{"verdict":"clear","diff_sha":"%s","gate":"make ci","exit_code":0}\n' "$head14" >"$T14_PROJECT/codegen/gate-pending/gate-result.json"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T14_PROJECT" | CODEGEN_BUILD_START_TS="$ts14" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "symlink target not a git repo → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T14_PROJECT" "$T14_NONGIT"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
