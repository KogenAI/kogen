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

# Create a fake repo root with a real templates/generator/prompt-budgets.txt
# so warn_if_over_cap resolves a committed budget row instead of silently
# skipping (the hook now reads templates/generator/prompt-budgets.txt via a
# parent-walk from the resolved real path — it no longer derives a cap from
# path-segment tiers). Paths must contain codegen/rules/_core/ or
# codegen/rules/roles/ to trigger the guard's allow branch.
TMP_CCG_ROOT="/tmp/test_ccg_$$"
TMP_CORE_DIR="$TMP_CCG_ROOT/codegen/rules/_core"
TMP_ROLES_DIR="$TMP_CCG_ROOT/codegen/rules/roles"
TMP_BUDGETS_DIR="$TMP_CCG_ROOT/templates/generator"
mkdir -p "$TMP_CORE_DIR" "$TMP_ROLES_DIR" "$TMP_BUDGETS_DIR"

# Fake budgets file: rows chosen so under/over-cap arithmetic below is easy to
# reason about. Note the hook's grep pattern is `^<key> ` — no glob suffix, so
# a row for one file never accidentally matches another file's edits. Keys
# use the codegen/rules/... form (no symlink in this fixture — the real repo
# stores rows under shared/rules/..., reached via the codegen/rules symlink
# that hooks_realpath resolves before the key is derived; this fixture skips
# the symlink and keys the budgets file directly under the on-disk path
# instead, which is an equivalent test of the walk-up + lookup logic).
cat >"$TMP_BUDGETS_DIR/prompt-budgets.txt" <<'EOF'
codegen/rules/_core/bash-discipline.md 48
codegen/rules/roles/developer.md 148
codegen/rules/_core/small-rule.md 50
codegen/rules/_core/new-rule.md 50
EOF

# Core file: 48 lines on disk, budget 48. An Edit adding 6 lines net → projected 53 > 48 → warn.
CORE_FILE="$TMP_CORE_DIR/bash-discipline.md"
printf '%s\n' {1..48} | awk '{print "line"}' >"$CORE_FILE"

# Roles file: 148 lines on disk, budget 148. An Edit adding 6 lines net → projected 153 > 148 → warn.
ROLES_FILE="$TMP_ROLES_DIR/developer.md"
printf '%s\n' {1..148} | awk '{print "line"}' >"$ROLES_FILE"

# Core file for under-cap test: 40 lines, budget 50. Edit replacing 1 with 1 → 40 < 50 → no warn.
CORE_UNDER_FILE="$TMP_CORE_DIR/small-rule.md"
printf '%s\n' {1..40} | awk '{print "line"}' >"$CORE_UNDER_FILE"

# No-budget-row file: valid rules path, but no row in the fake budgets file →
# silent skip regardless of size.
CORE_NOROW_FILE="$TMP_CORE_DIR/no-row-rule.md"
printf '%s\n' {1..48} | awk '{print "line"}' >"$CORE_NOROW_FILE"

# Clean up on exit.
_ccg_test_cleanup() { rm -rf "$TMP_CCG_ROOT"; }
trap '_ccg_test_cleanup' EXIT

# No-repo-root fixture: a rules path with NO templates/generator/prompt-budgets.txt
# anywhere up its parent chain → silent skip. Placed outside TMP_CCG_ROOT so it
# has no sibling budgets file.
TMP_NOROOT_ROOT="/tmp/test_ccg_noroot_$$"
TMP_NOROOT_CORE_DIR="$TMP_NOROOT_ROOT/codegen/rules/_core"
mkdir -p "$TMP_NOROOT_CORE_DIR"
NOROOT_FILE="$TMP_NOROOT_CORE_DIR/bash-discipline.md"
printf '%s\n' {1..48} | awk '{print "line"}' >"$NOROOT_FILE"
_ccg_test_cleanup_noroot() { rm -rf "$TMP_NOROOT_ROOT"; }
trap '_ccg_test_cleanup; _ccg_test_cleanup_noroot' EXIT

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

# W-1. Edit growing codegen/rules/_core/ past its committed budget (48) → warn present + allow.
run_warn_test "W-1: Edit _core past committed budget → warn + allow" "yes" \
    "$(_edit_json "$CORE_FILE" 6)"

# W-2. Edit growing codegen/rules/roles/ past its committed budget (148) → warn present + allow.
run_warn_test "W-2: Edit roles/ past committed budget → warn + allow" "yes" \
    "$(_edit_json "$ROLES_FILE" 6)"

# W-3. Edit staying under committed budget (50) → no warn + allow.
run_warn_test "W-3: Edit _core under committed budget → no warn + allow" "no" \
    "$(_edit_json "$CORE_UNDER_FILE" 1 "line")"

# W-4. Write content with 55 lines to _core path (budget 48) → warn + allow.
run_warn_test "W-4: Write _core content over committed budget → warn + allow" "yes" \
    "$(_write_json "$TMP_CORE_DIR/new-rule.md" 55)"

# W-5. Over-cap path but missing new_string AND old_string → fail-open (no warn) + allow.
run_warn_test "W-5: Missing new_string/old_string → no warn, fail-open + allow" "no" \
    "$(jq -n --arg fp "$CORE_FILE" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp},agent_type:"context-curator",agent_id:"abc"}')"

# W-6. Over-cap path is context/foo.md → no warn + allow (context not gated by cap).
run_warn_test "W-6: context/foo.md (not rules path) → no warn + allow" "no" \
    "$(jq -n '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:"/project/context/foo.md",old_string:"a",new_string:"b"},agent_type:"context-curator",agent_id:"abc"}')"

# W-7. Valid rules path, but no row for this file in the (real) budgets file → silent skip.
run_warn_test "W-7: no budget row for this file → no warn (silent skip)" "no" \
    "$(_edit_json "$CORE_NOROW_FILE" 6)"

# W-8. Valid rules path, but NO templates/generator/prompt-budgets.txt reachable
# anywhere up the parent chain (no fake repo root planted) → silent skip.
run_warn_test "W-8: no reachable budgets file → no warn (silent skip)" "no" \
    "$(_edit_json "$NOROOT_FILE" 6)"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
