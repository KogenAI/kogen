#!/bin/bash
# codex-shape-guard_test.sh — unit tests for codex-shape-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/codex-shape-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local codex_role="${4:-}"

    local stdout
    stdout=$(printf '%s' "$input" | CODEX_ROLE="$codex_role" bash "$GUARD" 2>/dev/null || true)

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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: CODEX_ROLE unset — hook is no-op (allow anything).
FIXTURE_UNSET='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1 +1 @@\n-old\n+new\n"}}'
run_test "no CODEX_ROLE — hook no-op, allows" "0" "$FIXTURE_UNSET" ""

# Test 2: CODEX_ROLE=shape + patch under codegen/pitches/draft/ — ALLOW.
FIXTURE_PITCHES='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/codegen/pitches/draft/foo.md\n+++ b/codegen/pitches/draft/foo.md\n@@ -1 +1 @@\n-old\n+new\n"}}'
run_test "CODEX_ROLE=shape + patch under codegen/pitches/draft/ allows" "0" "$FIXTURE_PITCHES" "shape"

# Test 3: CODEX_ROLE=shape + patch under lib/ — DENY.
FIXTURE_LIB='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1 +1 @@\n-old\n+new\n"}}'
run_test "CODEX_ROLE=shape + patch under lib/ blocks" "2" "$FIXTURE_LIB" "shape"

# Test 4: CODEX_ROLE=shape + non-apply_patch tool — ALLOW (hook only gates apply_patch).
FIXTURE_SHELL='{"hook_event_name":"PreToolUse","tool_name":"shell","tool_input":{"command":"ls"}}'
run_test "CODEX_ROLE=shape + non-apply_patch tool allows" "0" "$FIXTURE_SHELL" "shape"

# Test 5: CODEX_ROLE=refactor + patch under codegen/pitches/draft/ — ALLOW.
FIXTURE_REFACTOR_PITCHES='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/codegen/pitches/draft/foo.md\n+++ b/codegen/pitches/draft/foo.md\n@@ -1 +1 @@\n-old\n+new\n"}}'
run_test "CODEX_ROLE=refactor + patch under codegen/pitches/draft/ allows" "0" "$FIXTURE_REFACTOR_PITCHES" "refactor"

# Test 6: CODEX_ROLE=refactor + patch under lib/ — DENY.
FIXTURE_REFACTOR_LIB='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1 +1 @@\n-old\n+new\n"}}'
run_test "CODEX_ROLE=refactor + patch under lib/ blocks" "2" "$FIXTURE_REFACTOR_LIB" "refactor"

# Test 7: CODEX_ROLE=design (old role) — hook is no-op (design no longer recognized).
FIXTURE_DESIGN='{"hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"patch":"--- a/lib/foo.ex\n+++ b/lib/foo.ex\n@@ -1 +1 @@\n-old\n+new\n"}}'
run_test "CODEX_ROLE=design (legacy) — hook no-op, allows" "0" "$FIXTURE_DESIGN" "design"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
