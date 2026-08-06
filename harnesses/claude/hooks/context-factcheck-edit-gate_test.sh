#!/bin/bash
# context-factcheck-edit-gate_test.sh — unit tests for context-factcheck-edit-gate.sh
#
# Tests:
#   1: Write context/foo.md content with `_`->`*` corruption → DENY
#   2: Write context/foo.md clean content → ALLOW
#   3: Edit context/foo.md folding to corruption → DENY
#   4: MultiEdit context/foo.md folding to corruption → DENY
#   5: Write lib/foo.ex with corruption-shaped content → ALLOW (path gate)
#   6: Bash tool with corruption-shaped payload → ALLOW (tool gate)
#   7: FILE_PATH empty → ALLOW (graceful)
#   8: Write context/sub/nested.md corruption → ALLOW (subdir excluded)
#   9: Write CLAUDE.md with corruption → DENY (root doc, not just context/)
#  10: deny message contains a "<doc>:<linenum>"-shaped substring AND does NOT
#      contain "committer"
#  11: outside a git repo → ALLOW (fail-open)
#  12: Write context/big.md missing content field → ALLOW (fail-open unparseable)
#  13: Edit context/new.md not yet on disk, new_string clean → ALLOW
#  14: Write context/foo.md referencing a REAL repo-root path (lib/real.ex,
#      created in the fixture) → ALLOW (proves resolution now hits the real
#      tree, not the empty tmp_root mirror)
#  15: Write context/foo.md referencing a path that does NOT exist anywhere
#      in the fixture repo → DENY (genuine stale-path violation still caught)
#  16: Edit fixing ONE of two pre-existing violations, leaving the other → ALLOW (monotonic)
#  17: Edit adding a NEW violation while pre-existing ones remain → DENY naming only the new one
#  18: Write to a brand-new file with a real violation still DENIES (no false-open on empty baseline)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/context-factcheck-edit-gate.sh"

pass=0
fail=0

FIXTURES=()
cleanup() {
    for d in "${FIXTURES[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# make_fixture <n> — create a throwaway git repo with context/, context/sub/,
# lib/, PROJECT_CONTEXT.md placeholder.
make_fixture() {
    local n="$1"
    local dir="/tmp/factcheck-edit-gate-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context/sub" "$dir/lib"
    (cd "$dir" && git init -q)
    : >"$dir/PROJECT_CONTEXT.md"
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE bash "$GUARD" 2>/dev/null || true)

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

# ---------------------------------------------------------------------------
# Test 1: Write context/foo.md content with `_`->`*` corruption → DENY
# ---------------------------------------------------------------------------
dir1=$(make_fixture 1)
payload1=$(jq -n --arg fp "$dir1/context/foo.md" --arg cwd "$dir1" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"see `lib/register*route.ex` corrupted\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write context/foo.md with corruption → DENY" "2" "$payload1"

# ---------------------------------------------------------------------------
# Test 2: Write context/foo.md clean content → ALLOW
# ---------------------------------------------------------------------------
dir2=$(make_fixture 2)
payload2=$(jq -n --arg fp "$dir2/context/foo.md" --arg cwd "$dir2" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"clean content, no claims here\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write context/foo.md clean content → ALLOW" "0" "$payload2"

# ---------------------------------------------------------------------------
# Test 3: Edit context/foo.md folding to corruption → DENY
# ---------------------------------------------------------------------------
dir3=$(make_fixture 3)
printf 'old content here\n' >"$dir3/context/foo.md"
payload3=$(jq -n --arg fp "$dir3/context/foo.md" --arg cwd "$dir3" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"old content here",new_string:"register*route corrupted"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Edit context/foo.md folding to corruption → DENY" "2" "$payload3"

# ---------------------------------------------------------------------------
# Test 4: MultiEdit context/foo.md folding to corruption → DENY
# ---------------------------------------------------------------------------
dir4=$(make_fixture 4)
printf 'old content here\n' >"$dir4/context/foo.md"
payload4=$(jq -n --arg fp "$dir4/context/foo.md" --arg cwd "$dir4" \
    '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"old content here",new_string:"register*route corrupted"}]},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "MultiEdit context/foo.md folding to corruption → DENY" "2" "$payload4"

# ---------------------------------------------------------------------------
# Test 5: Write lib/foo.ex with corruption-shaped content → ALLOW (path gate)
# ---------------------------------------------------------------------------
dir5=$(make_fixture 5)
payload5=$(jq -n --arg fp "$dir5/lib/foo.ex" --arg cwd "$dir5" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"register*route\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write lib/foo.ex with corruption-shaped content → ALLOW (path gate)" "0" "$payload5"

# ---------------------------------------------------------------------------
# Test 6: Bash tool with corruption-shaped payload → ALLOW (tool gate)
# ---------------------------------------------------------------------------
dir6=$(make_fixture 6)
payload6=$(jq -n --arg fp "$dir6/context/foo.md" --arg cwd "$dir6" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"echo register*route",file_path:$fp},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Bash tool with corruption-shaped payload → ALLOW (tool gate)" "0" "$payload6"

# ---------------------------------------------------------------------------
# Test 7: FILE_PATH empty → ALLOW (graceful)
# ---------------------------------------------------------------------------
dir7=$(make_fixture 7)
payload7=$(jq -n --arg cwd "$dir7" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{content:"x"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "FILE_PATH empty → ALLOW (graceful)" "0" "$payload7"

# ---------------------------------------------------------------------------
# Test 8: Write context/sub/nested.md corruption → ALLOW (subdir excluded)
# ---------------------------------------------------------------------------
dir8=$(make_fixture 8)
payload8=$(jq -n --arg fp "$dir8/context/sub/nested.md" --arg cwd "$dir8" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"register*route\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write context/sub/nested.md corruption → ALLOW (subdir excluded)" "0" "$payload8"

# ---------------------------------------------------------------------------
# Test 9: Write CLAUDE.md with corruption → DENY (root doc, not just context/)
# ---------------------------------------------------------------------------
dir9=$(make_fixture 9)
payload9=$(jq -n --arg fp "$dir9/CLAUDE.md" --arg cwd "$dir9" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"register*route\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write CLAUDE.md with corruption → DENY (root doc)" "2" "$payload9"

# ---------------------------------------------------------------------------
# Test 10: deny message contains a "<doc>:<linenum>"-shaped substring AND
# does NOT contain "committer"
# ---------------------------------------------------------------------------
dir10=$(make_fixture 10)
payload10=$(jq -n --arg fp "$dir10/context/foo.md" --arg cwd "$dir10" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"register*route\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

stdout10=$(printf '%s' "$payload10" | env -u CLAUDE_ROLE bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout10" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    printf '%s' "$stdout10" | grep -qE 'context/foo\.md:[0-9]+' &&
    ! printf '%s' "$stdout10" | grep -qi "committer"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny message has <doc>:<linenum>, not committer\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny message missing <doc>:<linenum>, or wrongly mentions committer\n  stdout: %s\n' "$stdout10"
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# Test 11: outside a git repo → ALLOW (fail-open)
# ---------------------------------------------------------------------------
dir11="/tmp/factcheck-edit-gate-test-11-nogit"
rm -rf "$dir11"
mkdir -p "$dir11/context"
FIXTURES+=("$dir11")
payload11=$(jq -n --arg fp "$dir11/context/foo.md" --arg cwd "$dir11" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"register*route\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "outside a git repo → ALLOW (fail-open)" "0" "$payload11"

# ---------------------------------------------------------------------------
# Test 12: Write context/big.md missing content field → ALLOW (fail-open)
# ---------------------------------------------------------------------------
dir12=$(make_fixture 12)
payload12=$(jq -n --arg fp "$dir12/context/big.md" --arg cwd "$dir12" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write context/big.md missing content field → ALLOW (fail-open)" "0" "$payload12"

# ---------------------------------------------------------------------------
# Test 13: Edit context/new.md not yet on disk, new_string clean → ALLOW
# ---------------------------------------------------------------------------
dir13=$(make_fixture 13)
payload13=$(jq -n --arg fp "$dir13/context/new.md" --arg cwd "$dir13" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"",new_string:"brand new clean doc\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Edit context/new.md not on disk, clean new_string → ALLOW" "0" "$payload13"

# ---------------------------------------------------------------------------
# Test 14: Write context/foo.md referencing a REAL repo-root path → ALLOW
# (proves claim resolution hits the real tree, not the empty tmp_root mirror)
# ---------------------------------------------------------------------------
dir14=$(make_fixture 14)
printf 'defmodule Real do\nend\n' >"$dir14/lib/real.ex"
payload14=$(jq -n --arg fp "$dir14/context/foo.md" --arg cwd "$dir14" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"see `lib/real.ex` for details\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write context/foo.md referencing REAL path lib/real.ex → ALLOW" "0" "$payload14"

# ---------------------------------------------------------------------------
# Test 15: Write context/foo.md referencing a path that does NOT exist
# anywhere in the fixture repo → DENY (genuine stale-path violation)
# ---------------------------------------------------------------------------
dir15=$(make_fixture 15)
payload15=$(jq -n --arg fp "$dir15/context/foo.md" --arg cwd "$dir15" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"see `lib/nonexistent_module.ex` for details\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write context/foo.md referencing STALE path lib/nonexistent_module.ex → DENY" "2" "$payload15"

# ---------------------------------------------------------------------------
# Test 16: Edit that FIXES one pre-existing violation but leaves a SECOND
# pre-existing violation (elsewhere in the same doc) untouched → ALLOW. The
# gate is monotonic — it denies only violations the edit ADDS, never ones
# already on disk. Before this fix, an incremental edit on a multi-reference
# doc that already carried pre-existing violations never converged (it kept
# re-denying the violation it did not touch).
# ---------------------------------------------------------------------------
dir16=$(make_fixture 16)
printf 'see `lib/missing_one.ex` for details.\n\nsee `lib/missing_two.ex` too.\n' >"$dir16/context/foo.md"
payload16=$(jq -n --arg fp "$dir16/context/foo.md" --arg cwd "$dir16" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"lib/missing_one.ex",new_string:"PROJECT_CONTEXT.md"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Edit fixing ONE of two pre-existing violations, leaving the other → ALLOW (monotonic)" "0" "$payload16"

# ---------------------------------------------------------------------------
# Test 17: Edit that leaves pre-existing violations untouched AND adds a
# genuinely NEW violation elsewhere in the same doc → DENY, naming only the
# NEW violation (not the pre-existing one it did not touch).
# ---------------------------------------------------------------------------
dir17=$(make_fixture 17)
printf 'see `lib/missing_one.ex` for details.\n' >"$dir17/context/foo.md"
payload17=$(jq -n --arg fp "$dir17/context/foo.md" --arg cwd "$dir17" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"for details.",new_string:"for details. Also see `lib/brand_new_missing.ex`."},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

stdout17=$(printf '%s' "$payload17" | env -u CLAUDE_ROLE bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout17" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    printf '%s' "$stdout17" | grep -q "brand_new_missing.ex" &&
    ! printf '%s' "$stdout17" | grep -q "missing_one.ex"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: Edit adding a new violation denies naming ONLY the new one\n'
    pass=$((pass + 1))
else
    printf 'FAIL: Edit adding a new violation should deny naming only the NEW violation\n  stdout: %s\n' "$stdout17"
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# Test 18: a Write to a BRAND-NEW file (nothing on disk to baseline against)
# still denies a real violation — the monotonic baseline must not
# accidentally fail-open when there is no pre-existing file.
# ---------------------------------------------------------------------------
dir18=$(make_fixture 18)
payload18=$(jq -n --arg fp "$dir18/context/new-file.md" --arg cwd "$dir18" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:"see `lib/does_not_exist.ex` for details\n"},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "Write to brand-new file with a real violation still DENIES (no false-open on empty baseline)" "2" "$payload18"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
