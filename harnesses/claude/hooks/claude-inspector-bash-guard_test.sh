#!/bin/bash
# claude-inspector-bash-guard_test.sh — unit tests for claude-inspector-bash-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/claude-inspector-bash-guard.sh"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
    local project_dir="${4:-$TMP_DIR}"
    local stdout
    stdout=$(
        export CLAUDE_PROJECT_DIR="$project_dir"
        printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true
    )

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s
' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: non-Bash tool — ALLOW (early exit)
FIXTURE_NON_BASH='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/foo"}}'
run_test "non-Bash tool allows" "0" "$FIXTURE_NON_BASH"

# Test 2: stderr-capture pipe `2>&1 | head` — ALLOW (was wrongly blocked; inspector agent)
FIXTURE_STDERR='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log --oneline 2>&1 | head"},"agent_type":"inspector","agent_id":"abc"}'
run_test "git log with 2>&1 pipe allows" "0" "$FIXTURE_STDERR"

# Test 3: redirect-overwrite — BLOCK (inspector agent)
FIXTURE_REDIRECT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo foo > bar.txt"},"agent_type":"inspector","agent_id":"abc"}'
run_test "redirect-overwrite blocks" "2" "$FIXTURE_REDIRECT"

# Test 4: grep DELETE in source — ALLOW (was wrongly blocked; inspector agent)
FIXTURE_GREP_SQL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep DELETE module.ex"},"agent_type":"inspector","agent_id":"abc"}'
run_test "grep DELETE keyword allows" "0" "$FIXTURE_GREP_SQL"

# Test 5: git log --grep=DROP — ALLOW (inspector agent)
FIXTURE_GIT_GREP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log --grep=DROP"},"agent_type":"inspector","agent_id":"abc"}'
run_test "git log --grep=DROP allows" "0" "$FIXTURE_GIT_GREP"

# Test 6: psql with DELETE — BLOCK (real SQL execution; inspector agent)
FIXTURE_PSQL_DELETE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"psql -c \"DELETE FROM users\""},"agent_type":"inspector","agent_id":"abc"}'
run_test "psql DELETE blocks" "2" "$FIXTURE_PSQL_DELETE"

# Test 7: pg_dump piped to grep DROP — ALLOW (inspection of dump output; inspector agent)
FIXTURE_PG_DUMP_GREP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"pg_dump app | grep DROP"},"agent_type":"inspector","agent_id":"abc"}'
run_test "pg_dump | grep DROP allows" "0" "$FIXTURE_PG_DUMP_GREP"

# Test 8: append-redirect >> — BLOCK (inspector agent)
FIXTURE_APPEND='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo foo >> bar.txt"},"agent_type":"inspector","agent_id":"abc"}'
run_test "append-redirect blocks" "2" "$FIXTURE_APPEND"

# Test 9: rm — BLOCK (inspector agent)
FIXTURE_RM='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rm foo.txt"},"agent_type":"inspector","agent_id":"abc"}'
run_test "rm blocks" "2" "$FIXTURE_RM"

# Test 10: 2>/dev/null — ALLOW (inspector agent)
FIXTURE_DEV_NULL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status 2>/dev/null"},"agent_type":"inspector","agent_id":"abc"}'
run_test "2>/dev/null allows" "0" "$FIXTURE_DEV_NULL"

# Test 11: AGENT_TYPE="" (orchestrator) + mkdir — ALLOW (non-inspector passes through)
FIXTURE_ORCHESTRATOR_MKDIR='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"mkdir codegen/logging/foo"},"agent_type":"","agent_id":""}'
run_test "orchestrator mkdir not blocked by inspector guard" "0" "$FIXTURE_ORCHESTRATOR_MKDIR"

# Test 12: AGENT_TYPE="developer-phoenix-backend" + heredoc — ALLOW (non-inspector passes through)
FIXTURE_DEV_HEREDOC='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat << EOF\nhello\nEOF"},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "developer heredoc not blocked by inspector guard" "0" "$FIXTURE_DEV_HEREDOC"

# Test 13: AGENT_TYPE="inspector" + path traversal ../  — BLOCK
FIXTURE_TRAVERSAL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat ../../../etc/passwd"},"agent_type":"inspector","agent_id":"abc"}'
run_test "inspector path traversal ../ blocks" "2" "$FIXTURE_TRAVERSAL"

# Test 14: AGENT_TYPE="inspector-phoenix" + path traversal — BLOCK
FIXTURE_TRAVERSAL_PHX='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls ../secret"},"agent_type":"inspector-phoenix","agent_id":"abc"}'
run_test "inspector-phoenix path traversal ../ blocks" "2" "$FIXTURE_TRAVERSAL_PHX"

# Test 15: AGENT_TYPE="inspector" + normal command without ../ — ALLOW
FIXTURE_NO_TRAVERSAL='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls /tmp/logs"},"agent_type":"inspector","agent_id":"abc"}'
run_test "inspector command without traversal allows" "0" "$FIXTURE_NO_TRAVERSAL" "$TMP_DIR"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
