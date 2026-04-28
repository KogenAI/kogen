#!/bin/bash
# inspector-read-guard_test.sh — unit tests for inspector-read-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/inspector-read-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local project_dir="${4:-/tmp}"

    actual_code=$(
        export CLAUDE_PROJECT_DIR="$project_dir"
        printf '%s' "$input" | bash "$GUARD" 2>/dev/null
        echo $?
    )

    if [ "$actual_code" = "$expected" ]; then
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected exit %s, got %s\n' "$desc" "$expected" "$actual_code"
        fail=$((fail + 1))
    fi
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Test 1: Read within project dir — ALLOW
PROJ_FILE="$TMP_DIR/lib/foo.ex"
mkdir -p "$(dirname "$PROJ_FILE")"
touch "$PROJ_FILE"
FIXTURE_IN='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$PROJ_FILE"'"}}'
run_test "Read within project dir allows" "0" "$FIXTURE_IN" "$TMP_DIR"

# Test 2: Read outside project dir — BLOCK
FIXTURE_OUT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"}}'
run_test "Read outside project dir blocks" "2" "$FIXTURE_OUT" "$TMP_DIR"

# Test 3: Bash tool — ALLOW (not a Read tool)
FIXTURE_BASH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls"}}'
run_test "Bash tool allowed" "0" "$FIXTURE_BASH" "$TMP_DIR"

# Test 4: Read with .. traversal — BLOCK
FIXTURE_DOTDOT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP_DIR/../../../etc/passwd"'"}}'
run_test "Read with .. traversal blocks" "2" "$FIXTURE_DOTDOT" "$TMP_DIR"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
