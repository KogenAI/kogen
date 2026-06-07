#!/bin/bash
# committer-write-allowlist_test.sh — unit tests for committer-write-allowlist.sh
# Ports cases 14-18 and 20 from committer-tool-guard_test.sh against the generated hook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-write-allowlist.sh"

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
REVIEWER='reviewer-phoenix'

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

# 20 (from original test numbering). reviewer-phoenix editing source → ALLOW (not this hook's job)
run_test "non-committer source edit ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"lib/foo.ex\"},\"agent_type\":\"$REVIEWER\",\"agent_id\":\"abc\"}"

# Bonus: Bash tool passes through (not Write/Edit)
run_test "committer Bash tool ALLOWED (not Write/Edit, different hook)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
