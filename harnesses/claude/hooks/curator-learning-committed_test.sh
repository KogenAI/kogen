#!/usr/bin/env bash
# curator-learning-committed_test.sh — unit tests for curator-learning-committed.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/curator-learning-committed.sh"

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

# make_project: init git repo with a .gitignore that excludes /codegen/
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
        printf '/codegen/\n' >.gitignore
        git add README .gitignore
        git commit -qm init
    )
    printf '%s' "$dir"
}

# make_input: build PreToolUse JSON for a Bash command
make_input() {
    local cmd="$1"
    local cwd="${2:-$PWD}"
    jq -n \
        --arg cmd "$cmd" \
        --arg cwd "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":"","agent_id":"abc","cwd":$cwd}'
}

# make_session_log: write a JSONL cycle log with a developer role event and,
# optionally, a context-curator role event, under codegen/logging/.
# $1 = project dir, $2 = curator role body (raw text; "" = no curator event)
make_session_log() {
    local project_dir="$1"
    local curator_body="$2"
    mkdir -p "$project_dir/codegen/logging"
    local log_path="$project_dir/codegen/logging/20260101_000000_test_cycle.jsonl"
    jq -c -n '{ev:"role",role:"developer-phoenix-backend",body:"Work done."}' >"$log_path"
    if [ -n "$curator_body" ]; then
        jq -c -n --arg body "$curator_body" '{ev:"role",role:"context-curator",body:$body}' >>"$log_path"
    fi
    printf '%s' "$log_path"
}

# ── Test 1: not a BUILD_RESULT: command → ALLOW ──────────────────────────────
T1=$(make_project)
out=$(make_input "echo hello" "$T1" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "not BUILD_RESULT: command → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T1"

# ── Test 2: CODEGEN_BUILD_START_TS unset → ALLOW ─────────────────────────────
T2=$(make_project)
out=$(make_input 'echo "BUILD_RESULT: success"' "$T2" | env -u CODEGEN_BUILD_START_TS bash "$HOOK" 2>/dev/null || true)
assert_not_contains "CODEGEN_BUILD_START_TS unset → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T2"

# ── Test 3: Files edited: none → ALLOW ───────────────────────────────────────
T3=$(make_project)
make_session_log "$T3" "Files edited: none" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T3" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "Files edited: none → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T3"

# ── Test 4: marker absent from section → ALLOW ───────────────────────────────
T4=$(make_project)
make_session_log "$T4" "Some other content without the marker." >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T4" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "marker absent → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T4"

# ── Test 5: all recorded files in HEAD → ALLOW ───────────────────────────────
T5=$(make_project)
# Commit the tracked file first
echo "content" >"$T5/context/dev.md"
mkdir -p "$T5/context"
echo "content" >"$T5/context/dev.md"
(cd "$T5" && git add context/dev.md && git commit -qm "add context file")
make_session_log "$T5" "Files edited: context/dev.md" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T5" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "all recorded files in HEAD → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T5"

# ── Test 6: one recorded file not in HEAD → DENY ─────────────────────────────
T6=$(make_project)
make_session_log "$T6" "Files edited: context/missing.md" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T6" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_contains "one file not in HEAD → DENY" '"permissionDecision"' "$out"
rm -rf "$T6"

# ── Test 7: multiple files, one missing → DENY ───────────────────────────────
T7=$(make_project)
mkdir -p "$T7/context"
echo "content" >"$T7/context/present.md"
(cd "$T7" && git add context/present.md && git commit -qm "add present file")
make_session_log "$T7" "Files edited: context/present.md context/absent.md" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T7" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_contains "multiple files, one missing → DENY" '"permissionDecision"' "$out"
rm -rf "$T7"

# ── Test 8: recorded file is gitignored (session log under /codegen/) → ALLOW ─
T8=$(make_project)
# Session log itself lives under codegen/ which is in .gitignore
log8=$(make_session_log "$T8" "Files edited: codegen/logging/20260101_000000_test_cycle.jsonl")
out=$(make_input 'echo "BUILD_RESULT: success"' "$T8" | CODEGEN_BUILD_START_TS="9999999999" TRANSCRIPT_PATH="" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "gitignored path dropped → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T8"

# ── Test 9: section absent entirely → ALLOW ──────────────────────────────────
T9=$(make_project)
make_session_log "$T9" "" >/dev/null # no curator section
out=$(make_input 'echo "BUILD_RESULT: success"' "$T9" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "section absent → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T9"

# ── Test 10: session log not found → ALLOW (fail-open) ───────────────────────
T10=$(make_project)
# Don't create any session log; codegen/logging/ does not exist
out=$(make_input 'echo "BUILD_RESULT: success"' "$T10" | CODEGEN_BUILD_START_TS="9999999999" TRANSCRIPT_PATH="" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "session log not found → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T10"

# ── Test 11: malformed marker (just "Files edited:" with nothing after) → ALLOW ─
T11=$(make_project)
make_session_log "$T11" "Files edited:" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T11" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "malformed marker (empty after colon) → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T11"

# ── Test 12: deny message names the missing file ──────────────────────────────
T12=$(make_project)
make_session_log "$T12" "Files edited: context/myfile.md" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T12" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_contains "deny message names missing file" 'context/myfile.md' "$out"
rm -rf "$T12"

# ── Test 13: deny message includes recovery instructions ─────────────────────
T13=$(make_project)
make_session_log "$T13" "Files edited: context/lostfile.md" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T13" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_contains "deny message mentions cap" '40,960-byte cap' "$out"
assert_contains "deny message mentions restage" 'restage' "$out"
rm -rf "$T13"

# ── Test 14: multi-path all present in HEAD → ALLOW ──────────────────────────
T14=$(make_project)
mkdir -p "$T14/context"
echo "a" >"$T14/context/file-a.md"
echo "b" >"$T14/context/file-b.md"
(cd "$T14" && git add context/file-a.md context/file-b.md && git commit -qm "add both")
make_session_log "$T14" "Files edited: context/file-a.md context/file-b.md" >/dev/null
out=$(make_input 'echo "BUILD_RESULT: success"' "$T14" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "multi-path all present → ALLOW" '"permissionDecision"' "$out"
rm -rf "$T14"

# ── Test 15: role-bounded extraction — marker in DEVELOPER role, curator says none → ALLOW ─
# The developer role event body contains "Files edited: context/development.md";
# the context-curator role event body contains "Files edited: none". The role
# selector (.role=="context-curator") must scope to the curator event only.
T15=$(make_project)
mkdir -p "$T15/context"
echo "content" >"$T15/context/development.md"
(cd "$T15" && git add context/development.md && git commit -qm "add development.md")
log15="$T15/codegen/logging/20260101_000000_test_cycle.jsonl"
mkdir -p "$T15/codegen/logging"
jq -c -n '{ev:"role",role:"developer-phoenix-backend",body:"Files edited: context/development.md"}' >"$log15"
jq -c -n '{ev:"role",role:"context-curator",body:"Files edited: none"}' >>"$log15"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T15" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "marker in developer role, curator=none → ALLOW (role-bounded)" '"permissionDecision"' "$out"
rm -rf "$T15"

# ── Test 16: lowercase marker in curator role body — strict format means fail-open (ALLOW) ─
# "files edited:" (lowercase f) does not match "^Files edited:" — hook must fail-open.
T16=$(make_project)
log16="$T16/codegen/logging/20260101_000000_test_cycle.jsonl"
mkdir -p "$T16/codegen/logging"
jq -c -n '{ev:"role",role:"context-curator",body:"files edited: context/foo.md"}' >"$log16"
out=$(make_input 'echo "BUILD_RESULT: success"' "$T16" | CODEGEN_BUILD_START_TS="9999999999" bash "$HOOK" 2>/dev/null || true)
assert_not_contains "lowercase marker in curator role → ALLOW (strict format)" '"permissionDecision"' "$out"
rm -rf "$T16"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
