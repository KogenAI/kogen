#!/bin/bash
# developer-static-no-manual-build_test.sh — unit tests for developer-static-no-manual-build.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/developer-static-no-manual-build.sh"

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

# ── DENY: build/verify commands ───────────────────────────────────────────────

# 1. node render-check.js → DENY
run_test "developer-static node render-check.js DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node render-check.js\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 2. node wiring-check.js → DENY
run_test "developer-static node wiring-check.js DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node wiring-check.js\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 3. npm run build → DENY
run_test "developer-static npm run build DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 4. npm build → DENY
run_test "developer-static npm build DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm build\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 5. npm run serve → DENY
run_test "developer-static npm run serve DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run serve\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 6. npm serve → DENY
run_test "developer-static npm serve DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm serve\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 7. vite build → DENY
run_test "developer-static vite build DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vite build\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 8. npx playwright test → DENY
run_test "developer-static npx playwright test DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npx playwright test\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 9. playwright (standalone) → DENY
run_test "developer-static playwright DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"playwright\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# ── ALLOW: safe commands ──────────────────────────────────────────────────────

# 10. git status → ALLOW (no match)
run_test "developer-static git status ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 11. cat src/index.html → ALLOW
run_test "developer-static cat src/index.html ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat src/index.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 12. npm test → ALLOW (test != build|serve)
run_test "developer-static npm test ALLOWED (not build/serve)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm test\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 13. vite preview → ALLOW (only vite build is denied)
run_test "developer-static vite preview ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vite preview\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# ── Role pass-through: non-developer-static agents ───────────────────────────

# 14. developer-phoenix-backend npm run build → ALLOW (different role)
run_test "developer-phoenix-backend npm run build ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build\"},\"agent_type\":\"$DEV_BACKEND\",\"agent_id\":\"abc\"}"

# 15. committer vite build → ALLOW (different role)
run_test "committer vite build ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"vite build\"},\"agent_type\":\"committer\",\"agent_id\":\"abc\"}"

# ── Tool pass-through: non-Bash tools ────────────────────────────────────────

# 16. Write tool → ALLOW (not Bash)
run_test "developer-static Write tool ALLOWED (not Bash)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"src/index.html\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# ── Edge cases ────────────────────────────────────────────────────────────────

# 17. npm install → ALLOW (install != build|serve)
run_test "developer-static npm install ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm install\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 18. mise exec -- npm run build → DENY (contains npm run build)
run_test "developer-static mise exec npm run build DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mise exec -- npm run build\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 19. codegen-log write narrating "npm run build" in heredoc body → ALLOW
run_test "developer-static codegen-log write narrating npm run build ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"codegen-log section --slug test --body @- <<EOF\\n## developer-static Section\\nDid NOT run npm run build manually — gate runs it on SubagentStop.\\nEOF\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

# 20. real standalone npm run build still blocked unchanged
run_test "developer-static real npm run build still DENIED (unchanged)" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build\"},\"agent_type\":\"$DEV_STATIC\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
