#!/bin/bash
# phoenix-backend-developer-guard_test.sh — unit tests for phoenix-backend-developer-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/phoenix-backend-developer-guard.sh"

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
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

BE="developer-phoenix-backend"
FE="developer-phoenix-frontend"

# 1. lib/<app>_web/ → BLOCK
run_test "Edit on lib/app_web/ BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app_web/live/user_live.ex\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 2. assets/ → BLOCK
run_test "Edit on assets/js/ BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/assets/js/app.js\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 3. priv/static/ → BLOCK
run_test "Edit on priv/static/ BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/priv/static/css/app.css\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 4. .heex file → BLOCK
run_test "Edit on .heex BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app_web/templates/page.html.heex\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 5. _html.ex → BLOCK
run_test "Edit on _html.ex BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app_web/controllers/page_html.ex\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 6. lib/<app>/ (non-_web, backend) → ALLOW
run_test "Edit on lib/my_app/ (backend) ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app/accounts/user.ex\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 7. priv/repo/migrations/ → ALLOW
run_test "Edit on priv/repo/migrations/ ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/priv/repo/migrations/20240101_create_users.exs\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 8. Frontend agent → ALLOW (pass-through, not this hook's job)
run_test "Edit by frontend agent ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app_web/live/user_live.ex\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 9. Read tool → ALLOW (not gated)
run_test "Read on _web path ALLOWED (not gated tool)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/app/lib/my_app_web/live/user_live.ex\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
