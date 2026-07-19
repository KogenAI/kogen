#!/bin/bash
# prompt-budget-writer-only_test.sh — unit tests for prompt-budget-writer-only.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/prompt-budget-writer-only.sh"

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

BUDGET_PATH="templates/generator/prompt-budgets.txt"
NON_BUDGET_MD="context/development.md"

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

# ── Raw Edit/Write/MultiEdit on the budget file → DENY ──
run_test "Write on budget file — DENY" "2" "$(make_write_fixture "$BUDGET_PATH")"
run_test "Edit on budget file — DENY" "2" "$(make_edit_fixture "$BUDGET_PATH")"
run_test "MultiEdit on budget file — DENY" "2" "$(make_multiedit_fixture "$BUDGET_PATH")"

# ── Edit/Write on an unrelated .md path → ALLOW ──
run_test "Write on non-budget .md path — ALLOW" "0" "$(make_write_fixture "$NON_BUDGET_MD")"
run_test "Edit on non-budget .md path — ALLOW" "0" "$(make_edit_fixture "$NON_BUDGET_MD")"

# ── Bash --write flag → DENY, wherever invoked ──
run_test "Bash prompt_size_budget.py --write — DENY" "2" "$(make_bash_fixture "python3 templates/generator/prompt_size_budget.py --write")"
run_test "Bash prompt_size_budget.py --check --write — DENY" "2" "$(make_bash_fixture "python3 templates/generator/prompt_size_budget.py --check --write")"

# ── Bash write-vocab into the budget file → DENY ──
run_test "Bash redirect > into budget file — DENY" "2" "$(make_bash_fixture "echo 'shared/rules/roles/developer.md 200' > templates/generator/prompt-budgets.txt")"
run_test "Bash append >> into budget file — DENY" "2" "$(make_bash_fixture "printf 'x' >> templates/generator/prompt-budgets.txt")"
run_test "Bash tee into budget file — DENY" "2" "$(make_bash_fixture "echo hi | tee -a templates/generator/prompt-budgets.txt")"
run_test "Bash sed -i in-place-edit on budget file — DENY" "2" "$(make_bash_fixture "sed -i '' 's/107/200/' templates/generator/prompt-budgets.txt")"
run_test "Bash mv into budget file path — DENY" "2" "$(make_bash_fixture "mv /tmp/foo.txt templates/generator/prompt-budgets.txt")"
run_test "Bash cp into budget file path — DENY" "2" "$(make_bash_fixture "cp /tmp/foo.txt templates/generator/prompt-budgets.txt")"

# ── Unrelated Bash — ALLOW ──
run_test "Bash --check (no --write) — ALLOW" "0" "$(make_bash_fixture "python3 templates/generator/prompt_size_budget.py --check")"
run_test "Bash unrelated git status — ALLOW" "0" "$(make_bash_fixture "git status")"
run_test "Bash unrelated read (cat other file) — ALLOW" "0" "$(make_bash_fixture "cat README.md")"

# ── codegen-log narrating the gated phrase in its body — ALLOW ──
run_test "codegen-log section narrating --write in body — ALLOW" "0" "$(make_bash_fixture "printf '%s' 'fixed prompt_size_budget.py --write remedy' | codegen-log section developer-phoenix-backend --slug foo")"

# ── the crossed cell (this pitch): a real codegen-log invocation CHAINED to
# a real write into the budget file must NOT be exempt — is_codegen_log_write
# requires exactly ONE hard-boundary group. MUST DENY. ──
run_test "chained codegen-log call && real redirect into budget file — DENY (crossed cell)" "2" \
    "$(make_bash_fixture "codegen-log init --slug foo && echo 'x 200' > templates/generator/prompt-budgets.txt")"

# ── BYPASS debug/shape/ops ──
run_test "debug role bypass on Write to budget file — ALLOW" "0" "$(make_write_fixture "$BUDGET_PATH")" "CLAUDE_ROLE=debug"
run_test "shape role bypass on Bash redirect into budget file — ALLOW" "0" "$(make_bash_fixture "echo hi > templates/generator/prompt-budgets.txt")" "CLAUDE_ROLE=shape"
run_test "ops role bypass on MultiEdit to budget file — ALLOW" "0" "$(make_multiedit_fixture "$BUDGET_PATH")" "CLAUDE_ROLE=ops"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
