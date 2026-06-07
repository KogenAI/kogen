#!/bin/bash
# committer-tool-guard_test.sh — unit tests for committer-tool-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-tool-guard.sh"

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

COMMITTER='committer'
BACKEND='developer-phoenix-backend'
REVIEWER='reviewer-phoenix'

# ── Bash: ALLOW (git commands and safe utilities) ──────────────────────────

# 1. git status → ALLOW
run_test "committer git status ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 2. git diff → ALLOW
run_test "committer git diff ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git diff\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 3. git diff --cached → ALLOW
run_test "committer git diff --cached ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git diff --cached\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 4. git add -A → ALLOW
run_test "committer git add -A ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git add -A\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 5. git commit -m "msg" → ALLOW
run_test "committer git commit -m ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"Add feature\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 6. git log → ALLOW
run_test "committer git log ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git log --oneline -5\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 7. git show → ALLOW
run_test "committer git show ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git show HEAD\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 8. echo ... | wc -c → ALLOW
run_test "committer echo | wc -c ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo -n \\\"subject line\\\" | wc -c\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# ── Bash: DENY (build/test/package-manager commands) ──────────────────────

# 9. make test → DENY
run_test "committer make test DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 10. mix test → DENY
run_test "committer mix test DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"mix test path/to/test.exs\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 11. npm run build → DENY
run_test "committer npm run build DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"npm run build\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 12. node script.js → DENY
run_test "committer node script.js DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"node script.js\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 13. pytest → DENY
run_test "committer pytest DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"pytest tests/\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# ── Write/Edit: ALLOW (canonical session log path) ─────────────────────────

# 14. Write to canonical session log → ALLOW
run_test "committer Write session log ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"codegen/logging/20260607_120000_session.md\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 15. Edit canonical session log → ALLOW
run_test "committer Edit session log ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"codegen/logging/20260607_120000_step1_my-task.md\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# ── Write/Edit: DENY (source files) ──────────────────────────────────────

# 16. Write to a hook ts file → DENY
run_test "committer Write hook ts DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"harnesses/claude/hooks/reviewer-guard-session-log-write.ts\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 17. Edit lib/foo.ex → DENY
run_test "committer Edit lib source DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"lib/foo.ex\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 18. Write scaffold.sh → DENY
run_test "committer Write scaffold.sh DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"scaffold.sh\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# ── Pass-through: non-committer agents ────────────────────────────────────

# 19. developer-phoenix-backend running make test → ALLOW (not this hook's job)
run_test "non-committer make test ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\"},\"agent_type\":\"$BACKEND\",\"agent_id\":\"abc\"}"

# 20. reviewer-phoenix editing source → ALLOW (not this hook's job)
run_test "non-committer source edit ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"lib/foo.ex\"},\"agent_type\":\"$REVIEWER\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
