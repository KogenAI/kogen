#!/bin/bash
# committer-bash-allowlist_test.sh — unit tests for committer-bash-allowlist.sh
# Ports cases 1-13 and 19 from committer-tool-guard_test.sh against the generated hook.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-bash-allowlist.sh"

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

# 8. echo ... | wc -c → ALLOW (echo and wc both in allowlist)
run_test "committer echo | wc -c ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo -n \\\"subject line\\\" | wc -c\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# 8b. codegen-log init → ALLOW
run_test "committer codegen-log init ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"codegen-log init --slug demo\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

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

# ── Pass-through: non-committer agents ────────────────────────────────────

# 19 (from original test numbering). developer-phoenix-backend running make test → ALLOW (not this hook's job)
run_test "non-committer make test ALLOWED (pass-through)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make test\"},\"agent_type\":\"$BACKEND\",\"agent_id\":\"abc\"}"

# Bonus: git push → DENY (allowlist does not include push; committer.md forbids it)
run_test "committer git push DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin main\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# Bonus: git pull → DENY
run_test "committer git pull DENIED" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git pull\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# Bonus: Write tool passes through (not Bash)
run_test "committer Write tool ALLOWED (not Bash, different hook)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"lib/foo.ex\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# ── Cross-repo: cd-prefix and git -C forms ────────────────────────────────

# cd-prefix + git commit → ALLOW
run_test "committer cd /some/repo && git commit ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd /some/repo && git commit -m \\\"x\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# git -C <path> commit → ALLOW (previously denied)
run_test "committer git -C /some/repo commit ALLOWED" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git -C /some/repo commit -m \\\"x\\\"\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

# cd-prefix with non-allowlisted post-&& command → DENY (no shell escape)
run_test "committer cd /tmp && rm -rf / DENIED (cd-prefix not a shell escape)" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cd /tmp && rm -rf /\"},\"agent_type\":\"$COMMITTER\",\"agent_id\":\"abc\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
