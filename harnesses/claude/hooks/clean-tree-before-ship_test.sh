#!/bin/bash
# clean-tree-before-ship_test.sh — unit tests for clean-tree-before-ship.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/clean-tree-before-ship.sh"

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

# ── Test 1: command without both literals → ALLOW ────────────────────────────
T1=$(make_project)
out=$(make_input "echo hello" "$T1" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "no match command → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T1"

# ── Test 2: ship mv, clean tree → ALLOW ──────────────────────────────────────
T2=$(make_project)
out=$(make_input "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md" "$T2" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "ship mv clean tree → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T2"

# ── Test 3: ship mv + untracked stray file → BLOCK ───────────────────────────
T3=$(make_project)
echo "stray" >"$T3/stray.txt"
out=$(make_input "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md" "$T3" | bash "$HOOK" 2>/dev/null || true)
assert_contains "ship mv + untracked stray → BLOCK (permissionDecision)" '"permissionDecision"' "$out"
assert_contains "BLOCK reason mentions working tree not clean" 'working tree not clean' "$out"
rm -rf "$T3"

# ── Test 4: ship mv + tracked uncommitted modification → BLOCK ────────────────
T4=$(make_project)
echo "modified" >"$T4/README"
out=$(make_input "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md" "$T4" | bash "$HOOK" 2>/dev/null || true)
assert_contains "ship mv + tracked mod → BLOCK (permissionDecision)" '"permissionDecision"' "$out"
assert_contains "tracked mod block reason mentions working tree not clean" 'working tree not clean' "$out"
rm -rf "$T4"

# ── Test 5: promotion mv (ready-only, no shipped/) → ALLOW ───────────────────
T5=$(make_project)
out=$(make_input "mv codegen/pitches/draft/x.md codegen/pitches/ready/x.md" "$T5" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "promotion mv (ready-only) → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T5"

# ── Test 6: non-Bash tool with both literals in a field → ALLOW ──────────────
T6=$(make_project)
input6=$(jq -n \
    --arg cwd "$T6" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/ready/x.md codegen/pitches/shipped/x.md"},"agent_type":"","agent_id":"abc","cwd":$cwd}')
out=$(printf '%s' "$input6" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-Bash tool with both literals → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T6"

# ── Test 7: cwd not a git repo → ALLOW (fail-open) ───────────────────────────
T7=$(mktemp -d)
out=$(make_input "mv codegen/pitches/ready/my-slug.md codegen/pitches/shipped/my-slug.md" "$T7" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "non-git-repo cwd → ALLOW (fail-open)" '"permissionDecision"' "$out"
rm -rf "$T7"

# ── Test 8: shipped-only mv (no ready/) → ALLOW ──────────────────────────────
T8=$(make_project)
out=$(make_input "mv codegen/pitches/shipped/a.md codegen/pitches/shipped/b.md" "$T8" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "shipped-only mv (no ready/) → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T8"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
