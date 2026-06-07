#!/bin/bash
# orchestrator-read-discipline_test.sh — unit tests for orchestrator-read-discipline.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/orchestrator-read-discipline.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    # Capture stdout — the hook emits a permissionDecision JSON envelope
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
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# Test 1: orchestrator Read on session log — ALLOW
FIXTURE_LOG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/logging/20260509_session.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on session log allows" "0" "$FIXTURE_LOG"

# Test 2: orchestrator Read on PROJECT_CONTEXT.md — BLOCK (loaded into system prompt, no re-read needed)
FIXTURE_PC='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"PROJECT_CONTEXT.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on PROJECT_CONTEXT.md blocks" "2" "$FIXTURE_PC"

# Test 3: orchestrator Read on AGENTS.md — BLOCK (loaded into system prompt, no re-read needed)
FIXTURE_AGENTS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"AGENTS.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on AGENTS.md blocks" "2" "$FIXTURE_AGENTS"

# Test 4: orchestrator Read on CLAUDE.md — BLOCK (loaded into system prompt, no re-read needed)
FIXTURE_CLAUDE='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"CLAUDE.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on CLAUDE.md blocks" "2" "$FIXTURE_CLAUDE"

# Test 5: orchestrator Read on lib/combobulate/apps.ex — BLOCK
FIXTURE_LIB='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on lib/ blocks" "2" "$FIXTURE_LIB"

# Test 6: orchestrator Read on config/runtime.exs — BLOCK
FIXTURE_CONFIG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"config/runtime.exs"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on config/ blocks" "2" "$FIXTURE_CONFIG"

# Test 7: subagent (non-empty agent_id) Read on lib/ — ALLOW
FIXTURE_SUBAGENT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"abc123","agent_type":"developer-phoenix-backend"}'
run_test "subagent Read on lib/ allows" "0" "$FIXTURE_SUBAGENT"

# Test 8: named agent (planner) — ALLOW (AGENT_TYPE non-empty, not orchestrator)
FIXTURE_PLANNER='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":"planner"}'
run_test "planner Read on lib/ allows (not orchestrator)" "0" "$FIXTURE_PLANNER"

# Test 9: non-Read tool — ALLOW
FIXTURE_WRITE='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"file_path":"lib/combobulate/foo.ex"},"agent_id":"","agent_type":""}'
run_test "non-Read tool allowed" "0" "$FIXTURE_WRITE"

# Test 10: orchestrator Read on absolute session log path — ALLOW
TMP_CWD="$(mktemp -d)"
ABS_LOG="${TMP_CWD}/codegen/logging/20260509_step4_test.md"
FIXTURE_ABS_LOG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_LOG"'"},"agent_id":"","agent_type":"","cwd":"'"$TMP_CWD"'"}'
run_test "orchestrator Read on absolute session log path allows" "0" "$FIXTURE_ABS_LOG"
rm -rf "$TMP_CWD"

# Test 11: orchestrator Read on absolute lib/ path — BLOCK
TMP_CWD2="$(mktemp -d)"
ABS_LIB="${TMP_CWD2}/lib/combobulate/foo.ex"
FIXTURE_ABS_LIB='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_LIB"'"},"agent_id":"","agent_type":"","cwd":"'"$TMP_CWD2"'"}'
run_test "orchestrator Read on absolute lib/ path blocks" "2" "$FIXTURE_ABS_LIB"
rm -rf "$TMP_CWD2"

# Test 12: orchestrator Read on codegen/rules/roles/orchestrator.md — ALLOW
FIXTURE_ORCH_DELEG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/roles/orchestrator.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/roles/orchestrator.md allows" "0" "$FIXTURE_ORCH_DELEG"

# Test 13: orchestrator Read on codegen/rules/_core/bash-discipline.md — ALLOW
FIXTURE_ORCH_COV='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/_core/bash-discipline.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/_core/bash-discipline.md allows" "0" "$FIXTURE_ORCH_COV"

# Test 14: orchestrator Read on codegen/rules/stacks/phoenix/developer.md — BLOCK (subagent stack rule, not orchestrator)
FIXTURE_SUBAGENT_PHOENIX='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/stacks/phoenix/developer.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/stacks/phoenix/developer.md blocks (subagent stack rule)" "2" "$FIXTURE_SUBAGENT_PHOENIX"

# Test 15: orchestrator Read on absolute orchestrator rule path — ALLOW
TMP_CWD3="$(mktemp -d)"
ABS_ORCH="${TMP_CWD3}/codegen/rules/roles/orchestrator.md"
FIXTURE_ABS_ORCH='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_ORCH"'"},"agent_id":"","agent_type":"","cwd":"'"$TMP_CWD3"'"}'
run_test "orchestrator Read on absolute orchestrator rule path allows" "0" "$FIXTURE_ABS_ORCH"
rm -rf "$TMP_CWD3"

# Test 16: orchestrator Read on codegen/rules/roles/developer.md — BLOCK (subagent role, not orchestrator)
FIXTURE_HARNESS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/roles/developer.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/roles/developer.md blocks (subagent role)" "2" "$FIXTURE_HARNESS"

# Test 17: orchestrator Read on codegen/token-budget-design.md — ALLOW (top-level design doc)
FIXTURE_DESIGN='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/token-budget-design.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/token-budget-design.md allows (top-level design doc)" "0" "$FIXTURE_DESIGN"

# Test 18: orchestrator Read on codegen/recipes/foo.md — BLOCK (subdir, not top-level)
FIXTURE_RECIPE='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/recipes/foo.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/recipes/foo.md blocks (subdir not allowed)" "2" "$FIXTURE_RECIPE"

# Test 19: orchestrator Read on codegen/templates/bar.md — BLOCK (subdir, not top-level)
FIXTURE_TEMPLATE='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/templates/bar.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/templates/bar.md blocks (subdir not allowed)" "2" "$FIXTURE_TEMPLATE"

# Test 20: orchestrator Read on codegen/rules/stacks/phoenix/orchestrator.md — ALLOW (Phoenix orchestrator rule)
FIXTURE_PHX_ORCH='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/stacks/phoenix/orchestrator.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/stacks/phoenix/orchestrator.md allows" "0" "$FIXTURE_PHX_ORCH"

# Test 21: orchestrator Read on codegen/rules/stacks/phoenix/_core.md — ALLOW (Phoenix orchestrator shared core)
FIXTURE_PHX_CORE='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/stacks/phoenix/_core.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/stacks/phoenix/_core.md allows" "0" "$FIXTURE_PHX_CORE"

# Test 22: orchestrator Read on codegen/rules/shared/git-readonly.md — ALLOW
FIXTURE_GIT_RO='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/rules/shared/git-readonly.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/rules/shared/git-readonly.md allows" "0" "$FIXTURE_GIT_RO"

# Test 23: orchestrator Read on codegen/pitches/draft/foo.md — ALLOW (/document re-read)
FIXTURE_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/draft/foo.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/pitches/draft/ allows" "0" "$FIXTURE_DRAFT"

# Test 24: orchestrator Read on codegen/pitches/ready/foo.md — ALLOW
FIXTURE_READY='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/ready/foo.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/pitches/ready/ allows" "0" "$FIXTURE_READY"

# Test 25: orchestrator Read on codegen/pitches/shipped/foo.md — ALLOW
FIXTURE_SHIPPED='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/pitches/shipped/foo.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/pitches/shipped/ allows" "0" "$FIXTURE_SHIPPED"

# Test 26: orchestrator Read on absolute codegen/pitches/draft/ path — ALLOW
TMP_CWD4="$(mktemp -d)"
ABS_DRAFT="${TMP_CWD4}/codegen/pitches/draft/foo.md"
FIXTURE_ABS_DRAFT='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_DRAFT"'"},"agent_id":"","agent_type":"","cwd":"'"$TMP_CWD4"'"}'
run_test "orchestrator Read on absolute codegen/pitches/draft/ path allows" "0" "$FIXTURE_ABS_DRAFT"
rm -rf "$TMP_CWD4"

# Test 27: CLAUDE_ROLE=debug bypasses read discipline — investigation sessions need full access
FIXTURE_DEBUG_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=debug run_test "CLAUDE_ROLE=debug bypasses read discipline" "0" "$FIXTURE_DEBUG_BYPASS"

# Test 28: CLAUDE_ROLE=shape bypasses read discipline — shaping sessions need full access (Phase 0 preload)
FIXTURE_SHAPE_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=shape run_test "CLAUDE_ROLE=shape bypasses read discipline" "0" "$FIXTURE_SHAPE_BYPASS"

# Test 28b: CLAUDE_ROLE=refactor bypasses read discipline
FIXTURE_REFACTOR_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=refactor run_test "CLAUDE_ROLE=refactor bypasses read discipline" "0" "$FIXTURE_REFACTOR_BYPASS"

# PI_ROLE parity tests

# Test 29: PI_ROLE=debug bypasses read discipline
FIXTURE_PI_DEBUG_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
PI_ROLE=debug run_test "PI_ROLE=debug bypasses read discipline" "0" "$FIXTURE_PI_DEBUG_BYPASS"

# Test 30: PI_ROLE=shape bypasses read discipline
FIXTURE_PI_SHAPE_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
PI_ROLE=shape run_test "PI_ROLE=shape bypasses read discipline" "0" "$FIXTURE_PI_SHAPE_BYPASS"

# Test 30b: PI_ROLE=refactor bypasses read discipline
FIXTURE_PI_REFACTOR_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
PI_ROLE=refactor run_test "PI_ROLE=refactor bypasses read discipline" "0" "$FIXTURE_PI_REFACTOR_BYPASS"

# Test 31: CLAUDE_ROLE=ops bypasses read discipline — ops runs on live boxes, full access needed
FIXTURE_OPS_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=ops run_test "CLAUDE_ROLE=ops bypasses read discipline" "0" "$FIXTURE_OPS_BYPASS"

# Test 32: PI_ROLE=ops bypasses read discipline
FIXTURE_PI_OPS_BYPASS='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"lib/combobulate/apps.ex"},"agent_id":"","agent_type":""}'
PI_ROLE=ops run_test "PI_ROLE=ops bypasses read discipline" "0" "$FIXTURE_PI_OPS_BYPASS"

# Test B18b: CLAUDE_ROLE=ops Bash grep — ALLOW (ops needs full local inspection)
FIXTURE_BASH_OPS_GREP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo"},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=ops run_test "CLAUDE_ROLE=ops Bash grep allows" "0" "$FIXTURE_BASH_OPS_GREP"

# Test 33: orchestrator Read codegen/PROJECT_CONTEXT.md (relative symlink form) — DENY
FIXTURE_PC_CODEGEN='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/PROJECT_CONTEXT.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/PROJECT_CONTEXT.md denies (symlink relative form)" "2" "$FIXTURE_PC_CODEGEN"

# Test 34: orchestrator Read absolute <cwd>/codegen/PROJECT_CONTEXT.md — DENY
TMP_CWD_PC="$(mktemp -d)"
ABS_PC="${TMP_CWD_PC}/codegen/PROJECT_CONTEXT.md"
FIXTURE_ABS_PC='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"'"$ABS_PC"'"},"agent_id":"","agent_type":"","cwd":"'"$TMP_CWD_PC"'"}'
run_test "orchestrator Read on absolute codegen/PROJECT_CONTEXT.md denies" "2" "$FIXTURE_ABS_PC"
rm -rf "$TMP_CWD_PC"

# Test 35: orchestrator Read codegen/token-budget-design.md — still ALLOW (regression guard)
FIXTURE_DESIGN_REG='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"codegen/token-budget-design.md"},"agent_id":"","agent_type":""}'
run_test "orchestrator Read on codegen/token-budget-design.md still allows (regression guard)" "0" "$FIXTURE_DESIGN_REG"

# ── Bash gate tests ──────────────────────────────────────────────────────────

# Test B1: orchestrator Bash grep -rn — DENY
FIXTURE_BASH_GREP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn foo lib/"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash grep -rn denies" "2" "$FIXTURE_BASH_GREP"

# Test B2: orchestrator Bash rg — DENY
FIXTURE_BASH_RG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rg foo"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash rg denies" "2" "$FIXTURE_BASH_RG"

# Test B3: orchestrator Bash find — DENY
FIXTURE_BASH_FIND='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find . -name '\''*.ex'\''"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash find denies" "2" "$FIXTURE_BASH_FIND"

# Test B4: orchestrator Bash ls — DENY
FIXTURE_BASH_LS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"ls lib/"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash ls denies" "2" "$FIXTURE_BASH_LS"

# Test B5: orchestrator Bash tree — DENY
FIXTURE_BASH_TREE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"tree lib/"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash tree denies" "2" "$FIXTURE_BASH_TREE"

# Test B6: orchestrator Bash cat — DENY
FIXTURE_BASH_CAT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"cat lib/foo.ex"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash cat denies" "2" "$FIXTURE_BASH_CAT"

# Test B7: orchestrator Bash leading whitespace grep — DENY
FIXTURE_BASH_WS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"  grep x"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash leading-whitespace grep denies" "2" "$FIXTURE_BASH_WS"

# Test B8: orchestrator Bash git status — ALLOW
FIXTURE_BASH_GIT_STATUS='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash git status allows" "0" "$FIXTURE_BASH_GIT_STATUS"

# Test B9: orchestrator Bash git diff — ALLOW
FIXTURE_BASH_GIT_DIFF='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git diff -- lib/foo.ex"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash git diff allows" "0" "$FIXTURE_BASH_GIT_DIFF"

# Test B10: orchestrator Bash git log — ALLOW
FIXTURE_BASH_GIT_LOG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log origin/main..HEAD --oneline"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash git log allows" "0" "$FIXTURE_BASH_GIT_LOG"

# Test B11: orchestrator Bash make gate-status — ALLOW
FIXTURE_BASH_GATE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"make gate-status"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash make gate-status allows" "0" "$FIXTURE_BASH_GATE"

# Test B12: orchestrator Bash date — ALLOW
FIXTURE_BASH_DATE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"date -u +%Y%m%d"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash date allows" "0" "$FIXTURE_BASH_DATE"

# Test B13: orchestrator Bash git log --grep= — ALLOW (grep not leading)
FIXTURE_BASH_GIT_LOG_GREP='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git log --grep=foo"},"agent_id":"","agent_type":""}'
run_test "orchestrator Bash git log --grep= allows (grep not leading)" "0" "$FIXTURE_BASH_GIT_LOG_GREP"

# Test B14: subagent (non-empty agent_id) Bash grep — ALLOW
FIXTURE_BASH_SUBAGENT='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn foo lib/"},"agent_id":"abc123","agent_type":"developer-phoenix-backend"}'
run_test "subagent Bash grep allows (not orchestrator)" "0" "$FIXTURE_BASH_SUBAGENT"

# Test B15: planner (agent_type=planner) Bash grep — ALLOW
FIXTURE_BASH_PLANNER='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep -rn foo lib/"},"agent_id":"","agent_type":"planner"}'
run_test "planner Bash grep allows (AGENT_TYPE non-empty)" "0" "$FIXTURE_BASH_PLANNER"

# Test B16: CLAUDE_ROLE=debug Bash grep — ALLOW
FIXTURE_BASH_DEBUG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo"},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=debug run_test "CLAUDE_ROLE=debug Bash grep allows" "0" "$FIXTURE_BASH_DEBUG"

# Test B17: CLAUDE_ROLE=shape Bash find — ALLOW
FIXTURE_BASH_SHAPE='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"find ."},"agent_id":"","agent_type":""}'
CLAUDE_ROLE=shape run_test "CLAUDE_ROLE=shape Bash find allows" "0" "$FIXTURE_BASH_SHAPE"

# Test B18: PI_ROLE=debug Bash grep — ALLOW
FIXTURE_BASH_PI_DEBUG='{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"grep foo"},"agent_id":"","agent_type":""}'
PI_ROLE=debug run_test "PI_ROLE=debug Bash grep allows" "0" "$FIXTURE_BASH_PI_DEBUG"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
