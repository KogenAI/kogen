#!/bin/bash
# committer-subject-length_test.sh — unit tests for committer-subject-length.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/committer-subject-length.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook now emits a permissionDecision JSON envelope
    # to stdout for deny outcomes (exit 0) instead of stderr + exit 2. We
    # translate the legacy expected values: "2" means "expect deny",
    # "0" means "expect allow (no deny envelope)".
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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# 49-byte message — ALLOW
MSG_49="Add user auth with JWT tokens (49 chars)"
FIXTURE_ALLOW='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_49"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with 49-byte message allows" "0" "$FIXTURE_ALLOW"

# 53-byte message — BLOCK
MSG_51="Add user auth feature with really long commit message"
FIXTURE_BLOCK='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_51"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with 51-byte message blocks" "2" "$FIXTURE_BLOCK"

# Non-committer agent — not gated by this hook (pre-commit-guard handles it)
FIXTURE_OTHER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"some message\""},"agent_type":"developer-phoenix-backend","agent_id":"abc"}'
run_test "non-committer git commit not gated by this hook" "0" "$FIXTURE_OTHER"

# Heredoc form — BLOCK (can't extract subject, deny to force explicit -m "subject")
HEREDOC_CMD='git commit -m "$(cat <<'"'"'EOF'"'"'\nAdd feature\nEOF\n)"'
FIXTURE_HEREDOC=$(jq -n \
    --arg cmd "$HEREDOC_CMD" \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":"committer","agent_id":"abc"}')
run_test "committer heredoc form is denied" "2" "$FIXTURE_HEREDOC"

# Exactly 50-byte message — ALLOW (boundary)
MSG_50="Add user auth feature with JWT tokens (50b)"
FIXTURE_50='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_50"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "committer with exactly 50-byte message allows" "0" "$FIXTURE_50"

# codegen-log write narrating a >50-byte subject in heredoc body — ALLOW
FIXTURE_LOG_WRITE=$(jq -n \
    --arg cmd 'codegen-log section --slug test --body @- <<EOF
## committer Section
Ran git commit -m "'"$MSG_51"'" — denied as expected (subject too long).
EOF' \
    '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":"committer","agent_id":"abc"}')
run_test "codegen-log write narrating long subject ALLOWED" "0" "$FIXTURE_LOG_WRITE"

# real standalone 51-byte message still BLOCKED unchanged
run_test "real 51-byte message still blocks (unchanged)" "2" "$FIXTURE_BLOCK"

# git commit-graph — not a real commit, must not be gated by this hook
FIXTURE_COMMIT_GRAPH='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-graph write"},"agent_type":"committer","agent_id":"abc"}'
run_test "git commit-graph allowed (word-boundary fix)" "0" "$FIXTURE_COMMIT_GRAPH"

# git commit-tree — not a real commit, must not be gated by this hook
FIXTURE_COMMIT_TREE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit-tree abc123 -m msg"},"agent_type":"committer","agent_id":"abc"}'
run_test "git commit-tree allowed (word-boundary fix)" "0" "$FIXTURE_COMMIT_TREE"

# (this pitch) crossed cell — a REAL >50-byte commit message that also
# mentions "codegen-log" inside it. Not routed through codegen-log (command
# word is git) — the subject-length check still applies. MUST BLOCK.
MSG_51_WITH_TOKEN="ran codegen-log section developer with a really long message"
FIXTURE_TOKEN_LONG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit -m \"'"$MSG_51_WITH_TOKEN"'\""},"agent_type":"committer","agent_id":"abc"}'
run_test "real long subject mentioning codegen-log still BLOCKED (crossed cell)" "2" "$FIXTURE_TOKEN_LONG"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
