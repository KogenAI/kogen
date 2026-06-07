#!/bin/bash
# context-curator-guard_test.sh — unit tests for context-curator-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/context-curator-guard.sh"

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
        outcome="deny"
    else
        outcome="allow"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

CURATOR="context-curator"
OTHER="developer-phoenix-backend"

# 1. context/** (combobulate project) → ALLOW
run_test "Edit on context/domain.md ALLOWED" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Projects/AppBuilder/combobulate/context/domain.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 2. shared/rules/** direct path → DENY (use symlink path only)
run_test "Edit on codegen/shared/rules/some-rule.md DENIED (direct, use symlink)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Areas/Optimum/codegen/shared/rules/some-rule.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 3. codegen/logging/** → ALLOW
run_test "Write on codegen/logging/session.md ALLOWED" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/project/codegen/logging/20260520_session.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 4. lib/ → DENY
run_test "Edit on lib/my_app/accounts.ex DENIED" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/lib/my_app/accounts.ex\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 5. priv/ → DENY
run_test "Edit on priv/repo/migrations/001.exs DENIED" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/priv/repo/migrations/001.exs\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 6. assets/ → DENY
run_test "Write on assets/js/app.js DENIED" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"/project/assets/js/app.js\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 7. Makefile → DENY
run_test "Edit on Makefile DENIED" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/Makefile\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 8. Non-curator agent on lib/ → ALLOW (pass-through)
run_test "Edit on lib/ by non-curator ALLOWED (pass-through)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/lib/my_app/accounts.ex\"},\"agent_type\":\"$OTHER\",\"agent_id\":\"abc\"}"

# 9. Non-curator agent on Makefile → ALLOW (pass-through)
run_test "Edit on Makefile by non-curator ALLOWED (pass-through)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/Makefile\"},\"agent_type\":\"$OTHER\",\"agent_id\":\"abc\"}"

# 10. Read tool on denied path → ALLOW (Read not gated)
run_test "Read on lib/ by curator ALLOWED (tool not gated)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"/project/lib/my_app/accounts.ex\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 11. shared/rules/ subdirectory direct path → DENY (use symlink path only)
run_test "MultiEdit on codegen/shared/rules/roles/orchestrator.md DENIED (direct, use symlink)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"MultiEdit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Areas/Optimum/codegen/shared/rules/roles/orchestrator.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 12. shared/rules nested path direct → DENY (use symlink path only)
run_test "Edit on codegen/shared/rules/stacks/phoenix/_core.md DENIED (direct, use symlink)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Areas/Optimum/codegen/shared/rules/stacks/phoenix/_core.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 13. Empty file path → ALLOW (defensive)
run_test "Empty file path ALLOWED (defensive)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 14. codegen/shared/recipes/ → DENY (shared/rules allow must not over-match sibling shared/ dirs)
run_test "Edit on codegen/shared/recipes/x.md DENIED (not caught by shared/rules allow)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Areas/Optimum/codegen/shared/recipes/x.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 15. downstream symlink path codegen/rules/** → ALLOW
run_test "Edit on downstream codegen/rules/foo.md ALLOWED (symlink path)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Projects/myapp/codegen/rules/foo.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 16. downstream symlink path codegen/rules/ nested → ALLOW
run_test "Edit on downstream codegen/rules/roles/developer.md ALLOWED (symlink nested)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Projects/myapp/codegen/rules/roles/developer.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 17. downstream codegen/recipes/ → DENY (boundary: rules allow must not over-match sibling dirs)
run_test "Edit on downstream codegen/recipes/x.md DENIED (not rules)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Projects/myapp/codegen/recipes/x.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 18. downstream codegen/rulesets/ → DENY (must not match on prefix similarity)
run_test "Edit on downstream codegen/rulesets/x.md DENIED (rulesets not rules)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Projects/myapp/codegen/rulesets/x.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 19. /codegen/shared/rules/foo.md wrong pattern → DENY (must not accept)
run_test "Edit on /codegen/shared/rules/foo.md DENIED (wrong pattern, not symlink)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/codegen/shared/rules/foo.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 20. codegen/rules/** as absolute path → ALLOW (symlink path)
run_test "Edit on /project/codegen/rules/stacks/phoenix/core.md ALLOWED (symlink path)" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/codegen/rules/stacks/phoenix/core.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
