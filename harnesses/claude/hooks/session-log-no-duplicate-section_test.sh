#!/bin/bash
# session-log-no-duplicate-section_test.sh — unit tests for session-log-no-duplicate-section.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/session-log-no-duplicate-section.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local extra_env="${4:-}"

    local stdout
    if [ -n "$extra_env" ]; then
        stdout=$(printf '%s' "$input" | env $extra_env bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)
    fi

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

LOG_DIR="$TMP_DIR/codegen/logging"
mkdir -p "$LOG_DIR"

LOG_FILE="$LOG_DIR/foo_session.md"
touch "$LOG_FILE"

# Helper: build a Write fixture. Args: file_path content
make_write_fixture() {
    local fp="$1" content="$2"
    jq -n --arg fp "$fp" --arg c "$content" \
        '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp,"content":$c},"agent_type":""}'
}

# Helper: build an Edit fixture. Args: file_path new_string agent_type
make_edit_fixture() {
    local fp="$1" ns="$2" at="$3"
    jq -n --arg fp "$fp" --arg ns "$ns" --arg at "$at" \
        '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"","new_string":$ns},"agent_type":$at}'
}

# ── Test 1: Write with duplicated "## developer-phoenix-backend Section" → DENY ──
CONTENT_DUP=$(printf '# Step\n\n## developer-phoenix-backend Section\n\nbody\n\n## developer-phoenix-backend Section\n\ndup')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT_DUP")
run_test "Write with duplicate header in content — DENY" "2" "$FIXTURE"

# ── Test 2: Write with ## Plan only and one role header once → ALLOW ──
CONTENT_OK=$(printf '# Step\n\n## Plan\n\nplan text\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT_OK")
run_test "Write with Plan and one role header — ALLOW" "0" "$FIXTURE"

# ── Test 3: Write with two different role headers once each → ALLOW ──
CONTENT_TWO=$(printf '## planner-phoenix Section\n\nplan\n\n## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT_TWO")
run_test "Write with two different role headers once each — ALLOW" "0" "$FIXTURE"

# ── Test 4: Edit new_string adds header already on disk → DENY ──
printf '## developer-phoenix-backend Section\n\nExisting content\n' >"$LOG_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\nmore content')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$NS" "developer-phoenix-backend")
run_test "Edit re-adding header already on disk — DENY" "2" "$FIXTURE"

# ── Test 5: Edit new_string adds header NOT yet on disk → ALLOW (first insertion) ──
printf '# Step\n\n## Plan\n\nplan text\n' >"$LOG_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$NS" "developer-phoenix-backend")
run_test "Edit adding header not yet on disk — ALLOW" "0" "$FIXTURE"

# ── Test 6: Edit new_string body with no header → ALLOW ──
printf '# Step\n\n## developer-phoenix-backend Section\n\nbody\n' >"$LOG_FILE"
FIXTURE=$(make_edit_fixture "$LOG_FILE" "Additional content without any header" "developer-phoenix-backend")
run_test "Edit new_string with no header — ALLOW" "0" "$FIXTURE"

# ── Test 7: Edit new_string containing the same header twice → DENY (self-dup) ──
printf '# Step\n\n## Plan\n\nplan\n' >"$LOG_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\nbody\n\n## developer-phoenix-backend Section\n\ndup')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$NS" "developer-phoenix-backend")
run_test "Edit new_string with same header 2x in payload — DENY (self-dup)" "2" "$FIXTURE"

# ── Test 8: MultiEdit combined new_strings add header already on disk → DENY ──
printf '## developer-phoenix-backend Section\n\nbody\n' >"$LOG_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\nmore')
FIXTURE=$(jq -n --arg fp "$LOG_FILE" --arg ns "$NS" \
    '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":"body","new_string":$ns}]},"agent_type":"developer-phoenix-backend"}')
run_test "MultiEdit adding header already on disk — DENY" "2" "$FIXTURE"

# ── Test 9: MultiEdit adding two DIFFERENT headers, none on disk → ALLOW ──
printf '# Step\n\n## Plan\n\nplan\n' >"$LOG_FILE"
NS1=$(printf '## reviewer-phoenix Section\n\nreview')
NS2=$(printf '## committer Section\n\ncommit')
FIXTURE=$(jq -n --arg fp "$LOG_FILE" --arg ns1 "$NS1" --arg ns2 "$NS2" \
    '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":"","new_string":$ns1},{"old_string":"","new_string":$ns2}]},"agent_type":""}')
run_test "MultiEdit adding two different headers, none on disk — ALLOW" "0" "$FIXTURE"

# ── Test 10: MultiEdit whose two edits each add the SAME header → DENY (cross-edit self-dup) ──
printf '# Step\n\n## Plan\n\nplan\n' >"$LOG_FILE"
NS_DUP=$(printf '## reviewer-phoenix Section\n\nreview')
FIXTURE=$(jq -n --arg fp "$LOG_FILE" --arg ns "$NS_DUP" \
    '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":"","new_string":$ns},{"old_string":"","new_string":$ns}]},"agent_type":""}')
run_test "MultiEdit two edits each adding same header — DENY" "2" "$FIXTURE"

# ── Test 11: Non-logging path Edit duplicating a header → ALLOW (not a session log) ──
OTHER_FILE="$TMP_DIR/lib/foo.ex"
mkdir -p "$(dirname "$OTHER_FILE")"
touch "$OTHER_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\n## developer-phoenix-backend Section\n\n')
FIXTURE=$(make_edit_fixture "$OTHER_FILE" "$NS" "developer-phoenix-backend")
run_test "Edit on non-logging path with dup header — ALLOW" "0" "$FIXTURE"

# ── Test 12: Bypass: CLAUDE_ROLE=debug Edit duplicating a header → ALLOW ──
printf '## developer-phoenix-backend Section\n\nbody\n' >"$LOG_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\ndup')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$NS" "developer-phoenix-backend")
run_test "CLAUDE_ROLE=debug bypasses guard — ALLOW" "0" "$FIXTURE" "CLAUDE_ROLE=debug"

# ── Test 13: Bypass: CLAUDE_ROLE=shape Write with dup header → ALLOW ──
CONTENT_DUP2=$(printf '## reviewer-phoenix Section\n\nbody\n\n## reviewer-phoenix Section\n\ndup')
FIXTURE=$(make_write_fixture "$LOG_FILE" "$CONTENT_DUP2")
run_test "CLAUDE_ROLE=shape bypasses guard — ALLOW" "0" "$FIXTURE" "CLAUDE_ROLE=shape"

# ── Test 14: Bypass: CLAUDE_ROLE=ops Edit re-adding existing header → ALLOW ──
printf '## developer-phoenix-backend Section\n\nbody\n' >"$LOG_FILE"
NS=$(printf '## developer-phoenix-backend Section\n\nops dup')
FIXTURE=$(make_edit_fixture "$LOG_FILE" "$NS" "developer-phoenix-backend")
run_test "CLAUDE_ROLE=ops bypasses guard — ALLOW" "0" "$FIXTURE" "CLAUDE_ROLE=ops"

# ── Test 15: Edit on non-existent / unreadable log file → ALLOW (fail-open) ──
NONEXISTENT="$LOG_DIR/does-not-exist.md"
NS=$(printf '## developer-phoenix-backend Section\n\nbody')
FIXTURE=$(make_edit_fixture "$NONEXISTENT" "$NS" "developer-phoenix-backend")
run_test "Edit on non-existent log file — ALLOW (fail-open)" "0" "$FIXTURE"

# ── Test 16: Non-guarded tool (Bash) → ALLOW (tool gate) ──
printf '## developer-phoenix-backend Section\n\nbody\n' >"$LOG_FILE"
FIXTURE=$(jq -n --arg fp "$LOG_FILE" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"},"agent_type":"developer-phoenix-backend"}')
run_test "Bash tool not guarded — ALLOW" "0" "$FIXTURE"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
