#!/bin/bash
# phoenix-frontend-developer-guard_test.sh — unit tests for phoenix-frontend-developer-guard.sh
#
# Tests:
#   1. Edit on migration path       → BLOCKED (deny)
#   2. Edit on lib/app/contexts/    → BLOCKED
#   3. Edit on lib/app/services/    → BLOCKED
#   4. Edit on lib/app/workers/     → BLOCKED
#   5. Edit on lib/app/ (backend)   → BLOCKED
#   6. Edit on lib/app_web/         → ALLOWED
#   7. Edit on assets/              → ALLOWED
#   8. Non-frontend agent           → ALLOWED (pass-through)
#   9. Read tool                    → ALLOWED (not gated)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/phoenix-frontend-developer-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2" # "2" = deny, "0" = allow
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

FE="developer-phoenix-frontend"
BE="developer-phoenix-backend"

# 1. Migration path blocked
run_test "Edit on migration BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/priv/repo/migrations/20240101_create_users.exs\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 2. contexts/ blocked
run_test "Edit on lib/app/contexts/ BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app/contexts/accounts.ex\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 3. services/ blocked
run_test "Edit on lib/app/services/ BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app/services/email_service.ex\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 4. workers/ blocked
run_test "Edit on lib/app/workers/ BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app/workers/digest_worker.ex\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 5. lib/<app>/ (non-_web) blocked
run_test "Edit on lib/my_app/ (backend) BLOCKED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app/accounts/user.ex\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 6. lib/<app>_web/ allowed
run_test "Edit on lib/my_app_web/ ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/lib/my_app_web/live/user_live.ex\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 7. assets/ allowed
run_test "Edit on assets/js/ ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/assets/js/app.js\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

# 8. Backend agent passes through (not gated)
run_test "Edit on migration by backend agent ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/app/priv/repo/migrations/20240101_create_users.exs\"},\"agent_type\":\"$BE\",\"agent_id\":\"abc\"}"

# 9. Read tool not gated even for frontend agent
run_test "Read on migration ALLOWED (not gated tool)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/app/priv/repo/migrations/20240101_create_users.exs\"},\"agent_type\":\"$FE\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
