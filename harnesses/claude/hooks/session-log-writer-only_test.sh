#!/bin/bash
# session-log-writer-only_test.sh — unit tests for session-log-writer-only.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/session-log-writer-only.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local extra_env="${4:-}"

    local stdout
    if [ -n "$extra_env" ]; then
        stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u PI_ROLE $extra_env bash "$GUARD" 2>/dev/null || true)
    else
        stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)
    fi

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

LOG_PATH="codegen/logging/20260101_120000_test_session.md"
NON_LOG_MD="codegen/pitches/ready/some-pitch.md"

make_write_fixture() {
    local fp="$1"
    jq -n --arg fp "$fp" \
        '{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":$fp,"content":"whatever"},"agent_type":""}'
}

make_edit_fixture() {
    local fp="$1"
    jq -n --arg fp "$fp" \
        '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":$fp,"old_string":"a","new_string":"b"},"agent_type":""}'
}

make_multiedit_fixture() {
    local fp="$1"
    jq -n --arg fp "$fp" \
        '{"hook_event_name":"PreToolUse","tool_name":"MultiEdit","tool_input":{"file_path":$fp,"edits":[{"old_string":"a","new_string":"b"}]},"agent_type":""}'
}

make_bash_fixture() {
    local cmd="$1"
    jq -n --arg cmd "$cmd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":$cmd},"agent_type":""}'
}

# ── Raw Edit/Write/MultiEdit on a codegen/logging/*.md path → DENY (3) ──
run_test "Write on session log path — DENY" "2" "$(make_write_fixture "$LOG_PATH")"
run_test "Edit on session log path — DENY" "2" "$(make_edit_fixture "$LOG_PATH")"
run_test "MultiEdit on session log path — DENY" "2" "$(make_multiedit_fixture "$LOG_PATH")"

# ── Edit/Write on a non-log .md path → ALLOW ──
run_test "Write on non-log .md path — ALLOW" "0" "$(make_write_fixture "$NON_LOG_MD")"
run_test "Edit on non-log .md path — ALLOW" "0" "$(make_edit_fixture "$NON_LOG_MD")"

# ── Bash writes into a log (redirect, tee, in-place-stream-edit, move-into-log) → DENY (4) ──
run_test "Bash redirect > into log — DENY" "2" "$(make_bash_fixture "echo hi > codegen/logging/20260101_120000_test_session.md")"
run_test "Bash append >> into log — DENY" "2" "$(make_bash_fixture "printf 'x' >> codegen/logging/20260101_120000_test_session.md")"
run_test "Bash tee into log — DENY" "2" "$(make_bash_fixture "echo hi | tee -a codegen/logging/20260101_120000_test_session.md")"
run_test "Bash sed -i in-place-edit on log — DENY" "2" "$(make_bash_fixture "sed -i '' 's/a/b/' codegen/logging/20260101_120000_test_session.md")"
run_test "Bash mv into log path — DENY" "2" "$(make_bash_fixture "mv /tmp/foo.md codegen/logging/20260101_120000_test_session.md")"

# ── codegen-log init/section/section --role/append Bash → ALLOW (4) ──
run_test "Bash codegen-log init — ALLOW" "0" "$(make_bash_fixture "codegen-log init --slug demo")"
run_test "Bash codegen-log section --body @- — ALLOW" "0" "$(make_bash_fixture "printf 'x' | codegen-log section --body @-")"
run_test "Bash codegen-log section --role — ALLOW" "0" "$(make_bash_fixture "printf '' | codegen-log section --role reviewer-phoenix --body @-")"
run_test "Bash codegen-log append --role — ALLOW" "0" "$(make_bash_fixture "printf 'x' | codegen-log append --role committer --body @-")"

# ── Unrelated git/read Bash → ALLOW ──
run_test "Bash unrelated git status — ALLOW" "0" "$(make_bash_fixture "git status")"
run_test "Bash unrelated read (cat other file) — ALLOW" "0" "$(make_bash_fixture "cat README.md")"

# ── BYPASS debug/shape/ops ──
run_test "debug role bypass on Write to log — ALLOW" "0" "$(make_write_fixture "$LOG_PATH")" "CLAUDE_ROLE=debug"
run_test "shape role bypass on Bash redirect into log — ALLOW" "0" "$(make_bash_fixture "echo hi > codegen/logging/20260101_120000_test_session.md")" "CLAUDE_ROLE=shape"
run_test "ops role bypass on MultiEdit to log — ALLOW" "0" "$(make_multiedit_fixture "$LOG_PATH")" "CLAUDE_ROLE=ops"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
