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

# 1. context/** (user app project) → ALLOW
run_test "Edit on context/domain.md ALLOWED" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/almirsarajcic/Projects/AppBuilder/my_app/context/domain.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

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

# 21. Downstream codegen/PROJECT_CONTEXT.md → ALLOW (curator maintains index rows)
run_test "Edit on /Users/x/Projects/myapp/codegen/PROJECT_CONTEXT.md ALLOWED" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/Users/x/Projects/myapp/codegen/PROJECT_CONTEXT.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 22. Repo-root PROJECT_CONTEXT.md → ALLOW
run_test "Edit on /project/PROJECT_CONTEXT.md ALLOWED" "allow" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/PROJECT_CONTEXT.md\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 23. PROJECT_CONTEXT.md.bak → DENY (anchor prevents over-match)
run_test "Edit on /project/PROJECT_CONTEXT.md.bak DENIED (anchor)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/PROJECT_CONTEXT.md.bak\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# 24. MY_PROJECT_CONTEXT.mdx → DENY (anchor)
run_test "Edit on /project/MY_PROJECT_CONTEXT.mdx DENIED (anchor)" "deny" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"/project/MY_PROJECT_CONTEXT.mdx\"},\"agent_type\":\"$CURATOR\",\"agent_id\":\"abc\"}"

# ---------------------------------------------------------------------------
# Warn-only line-budget tests
# ---------------------------------------------------------------------------
# run_warn_test: asserts that the outcome is still ALLOW and that the stderr
# warning is present (warn_expected="yes") or absent (warn_expected="no").
# Usage: run_warn_test "desc" "yes|no" "<json>"
run_warn_test() {
    local desc="$1"
    local warn_expected="$2"
    local input="$3"

    local stdout stderr
    stderr=$(printf '%s' "$input" | bash "$GUARD" 2>&1 1>/tmp/_ccg_stdout_$$) || true
    stdout=$(cat /tmp/_ccg_stdout_$$ 2>/dev/null) || stdout=""
    rm -f /tmp/_ccg_stdout_$$

    # Outcome must always be ALLOW.
    local outcome
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        outcome="deny"
    else
        outcome="allow"
    fi

    # Check warning presence.
    local warn_actual="no"
    if printf '%s' "$stderr" | grep -q 'context-curator-guard.*WARNING'; then
        warn_actual="yes"
    fi

    local ok=true
    if [ "$outcome" != "allow" ]; then
        ok=false
        printf 'FAIL: %s — expected allow, got deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
        return
    fi
    if [ "$warn_actual" != "$warn_expected" ]; then
        ok=false
        printf 'FAIL: %s — expected warn=%s, got warn=%s\n  stderr: %s\n' \
            "$desc" "$warn_expected" "$warn_actual" "$stderr"
        fail=$((fail + 1))
        return
    fi

    if "$ok"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# Create temp rule files for Edit tests that need a real on-disk file.
# Paths must contain codegen/rules/_core/ or codegen/rules/roles/ to trigger guard.
TMP_CCG_ROOT="/tmp/test_ccg_$$"
TMP_CORE_DIR="$TMP_CCG_ROOT/codegen/rules/_core"
TMP_ROLES_DIR="$TMP_CCG_ROOT/codegen/rules/roles"
mkdir -p "$TMP_CORE_DIR" "$TMP_ROLES_DIR"

# Core file: 48 lines on disk. An Edit adding 6 lines net → projected 54 > 50 → warn.
CORE_FILE="$TMP_CORE_DIR/bash-discipline.md"
printf '%s\n' {1..48} | awk '{print "line"}' >"$CORE_FILE"

# Roles file: 148 lines on disk. An Edit adding 6 lines net → projected 154 > 150 → warn.
ROLES_FILE="$TMP_ROLES_DIR/developer.md"
printf '%s\n' {1..148} | awk '{print "line"}' >"$ROLES_FILE"

# Core file for under-cap test: 40 lines. Edit replacing 1 with 1 → 40 < 50 → no warn.
CORE_UNDER_FILE="$TMP_CORE_DIR/small-rule.md"
printf '%s\n' {1..40} | awk '{print "line"}' >"$CORE_UNDER_FILE"

# Clean up on exit.
_ccg_test_cleanup() { rm -rf "$TMP_CCG_ROOT"; }
trap '_ccg_test_cleanup' EXIT

# Helper: build jq-encoded JSON for Edit with N new_string lines (via jq reduce).
# jq -n properly encodes \n as JSON escape sequences in the output.
_edit_json() {
    local fp="$1" new_nl="$2" old_str="${3:-line}"
    jq -n \
        --arg fp "$fp" \
        --arg old "$old_str" \
        --argjson new_nl "$new_nl" \
        '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:$old,new_string:(reduce range($new_nl) as $i (""; . + "x\n"))},agent_type:"context-curator",agent_id:"abc"}'
}

# Helper: build jq-encoded JSON for Write with N content lines.
_write_json() {
    local fp="$1" content_nl="$2"
    jq -n \
        --arg fp "$fp" \
        --argjson content_nl "$content_nl" \
        '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:(reduce range($content_nl) as $i (""; . + "x\n"))},agent_type:"context-curator",agent_id:"abc"}'
}

# W-1. Edit growing codegen/rules/_core/ past 50 → warn present + allow.
run_warn_test "W-1: Edit _core past 50 lines → warn + allow" "yes" \
    "$(_edit_json "$CORE_FILE" 6)"

# W-2. Edit growing codegen/rules/roles/ past 150 → warn present + allow.
run_warn_test "W-2: Edit roles/ past 150 lines → warn + allow" "yes" \
    "$(_edit_json "$ROLES_FILE" 6)"

# W-3. Edit staying under cap → no warn + allow.
run_warn_test "W-3: Edit _core under 50 lines → no warn + allow" "no" \
    "$(_edit_json "$CORE_UNDER_FILE" 1 "line")"

# W-4. Write content with 55 lines to _core path → warn + allow.
run_warn_test "W-4: Write _core content over 50 lines → warn + allow" "yes" \
    "$(_write_json "$TMP_CORE_DIR/new-rule.md" 55)"

# W-5. Over-cap path but missing new_string AND old_string → fail-open (no warn) + allow.
run_warn_test "W-5: Missing new_string/old_string → no warn, fail-open + allow" "no" \
    "$(jq -n --arg fp "$CORE_FILE" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp},agent_type:"context-curator",agent_id:"abc"}')"

# W-6. Over-cap path is context/foo.md → no warn + allow (context not gated by cap).
run_warn_test "W-6: context/foo.md (not rules path) → no warn + allow" "no" \
    "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:"/project/context/foo.md",old_string:"a",new_string:"b"},agent_type:"context-curator",agent_id:"abc"}')"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
