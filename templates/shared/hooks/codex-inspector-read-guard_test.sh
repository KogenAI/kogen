#!/bin/bash
# codex-inspector-read-guard_test.sh — unit tests for codex-inspector-read-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/codex-inspector-read-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local project_dir="${4:-/tmp}"
    local stdout
    stdout=$(
        export CODEX_PROJECT_DIR="$project_dir"
        printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true
    )

    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="2"
    else
        outcome="0"
    fi

    if [ "$outcome" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Test 1: read_file within project dir — ALLOW
PROJ_FILE="$TMP_DIR/lib/foo.ex"
mkdir -p "$(dirname "$PROJ_FILE")"
touch "$PROJ_FILE"
FIXTURE_IN='{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_input":{"file_path":"'"$PROJ_FILE"'"}}'
run_test "read_file within project dir allows" "0" "$FIXTURE_IN" "$TMP_DIR"

# Test 2: read_file outside project dir — BLOCK
FIXTURE_OUT='{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_input":{"file_path":"/etc/passwd"}}'
run_test "read_file outside project dir blocks" "2" "$FIXTURE_OUT" "$TMP_DIR"

# Test 3: shell tool — ALLOW (not a read_file tool)
FIXTURE_SHELL='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"ls"}}'
run_test "shell tool allowed" "0" "$FIXTURE_SHELL" "$TMP_DIR"

# Test 4: read_file with .. traversal — BLOCK
FIXTURE_DOTDOT='{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_input":{"file_path":"'"$TMP_DIR/../../../etc/passwd"'"}}'
run_test "read_file with .. traversal blocks" "2" "$FIXTURE_DOTDOT" "$TMP_DIR"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
