#!/bin/bash
# developer-static-no-build-output-probe_test.sh — unit tests for developer-static-no-build-output-probe.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/developer-static-no-build-output-probe.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

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

DEV_STATIC='developer-static'
DEV_BACKEND='developer-phoenix-backend'

# ── DENY: Read build-output files ─────────────────────────────────────────────

# 1. Read public/index.html → DENY
run_test "developer-static Read public/index.html DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"public/index.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 2. Read dist/app.js → DENY
run_test "developer-static Read dist/app.js DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"dist/app.js\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 3. Read public/assets/main.css → DENY
run_test "developer-static Read public/assets/main.css DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"public/assets/main.css\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 4. Grep with .tool_input.path=public/ → DENY (uses path field, not file_path)
run_test "developer-static Grep tool_input.path=public/ DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Grep\",\"tool_input\":{\"path\":\"public/\",\"pattern\":\"hello\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 5. Glob with .tool_input.path=dist/** → DENY
run_test "developer-static Glob tool_input.path=dist/** DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Glob\",\"tool_input\":{\"path\":\"dist/**\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 6. Grep with path containing /public/ segment → DENY
run_test "developer-static Grep path nested /public/ DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Grep\",\"tool_input\":{\"path\":\"subdir/public/x\",\"pattern\":\"test\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 7. Read dist/index.html → DENY
run_test "developer-static Read dist/index.html DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"dist/index.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# ── ALLOW: source files ───────────────────────────────────────────────────────

# 8. Read src/index.html → ALLOW
run_test "developer-static Read src/index.html ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"src/index.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 9. Read assets/main.js → ALLOW
run_test "developer-static Read assets/main.js ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"assets/main.js\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 10. Grep with path=src/ → ALLOW
run_test "developer-static Grep path=src/ ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Grep\",\"tool_input\":{\"path\":\"src/\",\"pattern\":\"hello\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 11. Read mypublic.md → ALLOW (no /public/ segment)
run_test "developer-static Read mypublic.md ALLOWED (no /public/ segment)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"mypublic.md\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 12. Read republic/x.md → ALLOW (anchored /public/, not substring match)
run_test "developer-static Read republic/x.md ALLOWED (not /public/)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"republic/x.md\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 13. Read redistribution/y.js → ALLOW (no /dist/ segment)
run_test "developer-static Read redistribution/y.js ALLOWED (no /dist/ segment)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"redistribution/y.js\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# ── Role pass-through: non-developer-static agents ───────────────────────────

# 14. developer-phoenix-backend Read public/x → ALLOW (different role)
run_test "developer-phoenix-backend Read public/x ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"public/x\"},\"agent_type\":\"$DEV_BACKEND\",\"agent_id\":\"abc\"}"

# 15. committer Glob dist/** → ALLOW (different role)
run_test "committer Glob dist/** ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Glob\",\"tool_input\":{\"path\":\"dist/**\"},\"agent_type\":\"committer\",\"agent_id\":\"abc\"}"

# ── Tool pass-through: non-Read/Grep/Glob tools ──────────────────────────────

# 16. Bash tool → ALLOW (not Read/Grep/Glob)
run_test "developer-static Bash tool ALLOWED (not Read/Grep/Glob)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls public/\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 17. Write tool → ALLOW (not Read/Grep/Glob)
run_test "developer-static Write tool ALLOWED (not Read/Grep/Glob)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"public/index.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 18. Glob with path=src/**/*.html → ALLOW (no /public/ or /dist/)
run_test "developer-static Glob src/**/*.html ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Glob\",\"tool_input\":{\"path\":\"src/**/*.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
