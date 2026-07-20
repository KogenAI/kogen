#!/bin/bash
# curator-context-size-gate_test.sh — unit tests for curator-context-size-gate.sh
#
# Tests:
#   1: curator Write context/big.md content 50000 bytes → DENY
#   2: curator Write context/ok.md content 100 bytes → ALLOW
#   3: curator Write context/exact.md content exactly 40960 bytes → ALLOW (boundary)
#   4: curator Write context/over.md content 40961 bytes → DENY (one over)
#   5: curator Edit context/existing.md projected over cap → DENY
#   6: curator Edit context/existing.md projected under cap → ALLOW
#   7: non-curator (developer-phoenix-backend) Write context/big.md 50000 bytes → DENY (role-agnostic)
#   8: curator Bash tool with over-cap payload → ALLOW (tool gate)
#   9: curator Write lib/foo.ex 50000 bytes → ALLOW (path gate)
#  10: curator Write context/sub/nested.md 50000 bytes → ALLOW (subdir excluded)
#  11: curator MultiEdit context/big.md over cap → DENY (sums edits[] deltas)
#  12: curator Write context/big.md missing/empty content field → ALLOW (fail-open unparseable)
#  13: curator Edit context/new.md not yet on disk, new_string over cap → DENY
#  14: deny message contains "compress" AND does NOT contain "committer"
#  15: deny message contains the exact projected byte count and "40960-byte (40k) cap" substring
#  16: FILE_PATH empty → ALLOW (graceful)
#  17: curator MultiEdit context/small.md under cap → ALLOW
#  18: non-curator MultiEdit context/big.md over cap → DENY (role-agnostic MultiEdit)
#  19: curator Write PROJECT_CONTEXT.md content 50000 bytes → DENY (root doc)
#  20: curator Write codegen/PROJECT_CONTEXT.md content 50000 bytes → DENY (root doc variant)
#  21: curator Write PROJECT_CONTEXT.md content 100 bytes → ALLOW (root doc under cap)
#  22: curator Write context/sub/nested.md 50000 bytes → ALLOW (nested still excluded, post-widen)
#  23: outside a git repo → ALLOW (fail-open)
#  24: CLAUDE.md / AGENTS.md over cap → ALLOW (deliberately not gated)
#  25: PROJECT_CONTEXT.md over-cap deny message does NOT say "add the matching PROJECT_CONTEXT.md row"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/curator-context-size-gate.sh"

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
# lib/, codegen/ dirs (repo-root resolution requires a real git repo now).
make_fixture() {
    local n="$1"
    local dir="/tmp/curator-size-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context" "$dir/lib" "$dir/context/sub" "$dir/codegen"
    (cd "$dir" && git init -q)
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)

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
# Test 1: curator Write context/big.md content 50000 bytes → DENY
# ---------------------------------------------------------------------------
dir1=$(make_fixture 1)
content1=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload1=$(jq -n --arg fp "$dir1/context/big.md" --arg content "$content1" --arg cwd "$dir1" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/big.md content 50000 bytes → DENY" "2" "$payload1"

# ---------------------------------------------------------------------------
# Test 2: curator Write context/ok.md content 100 bytes → ALLOW
# ---------------------------------------------------------------------------
dir2=$(make_fixture 2)
content2=$(head -c 100 /dev/zero | tr '\0' 'x')
payload2=$(jq -n --arg fp "$dir2/context/ok.md" --arg content "$content2" --arg cwd "$dir2" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/ok.md content 100 bytes → ALLOW" "0" "$payload2"

# ---------------------------------------------------------------------------
# Test 3: curator Write context/exact.md content exactly 40960 bytes → ALLOW (boundary)
# ---------------------------------------------------------------------------
dir3=$(make_fixture 3)
content3=$(head -c 40960 /dev/zero | tr '\0' 'x')
payload3=$(jq -n --arg fp "$dir3/context/exact.md" --arg content "$content3" --arg cwd "$dir3" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/exact.md content exactly 40960 bytes → ALLOW (boundary)" "0" "$payload3"

# ---------------------------------------------------------------------------
# Test 4: curator Write context/over.md content 40961 bytes → DENY (one over)
# ---------------------------------------------------------------------------
dir4=$(make_fixture 4)
content4=$(head -c 40961 /dev/zero | tr '\0' 'x')
payload4=$(jq -n --arg fp "$dir4/context/over.md" --arg content "$content4" --arg cwd "$dir4" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/over.md content 40961 bytes → DENY (one over)" "2" "$payload4"

# ---------------------------------------------------------------------------
# Test 5: curator Edit context/existing.md projected over cap → DENY
# on-disk 40000 - old(10) + new(5000) = 44990
# ---------------------------------------------------------------------------
dir5=$(make_fixture 5)
head -c 40000 /dev/zero | tr '\0' 'x' >"$dir5/context/existing.md"
old5="0123456789"
new5=$(head -c 5000 /dev/zero | tr '\0' 'y')
# Ensure old_string is actually present so this mirrors a real Edit call shape
# (the hook does not verify presence — it only measures byte lengths).
payload5=$(jq -n --arg fp "$dir5/context/existing.md" --arg old "$old5" --arg new "$new5" --arg cwd "$dir5" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:$old,new_string:$new},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Edit context/existing.md projected over cap → DENY" "2" "$payload5"

# ---------------------------------------------------------------------------
# Test 6: curator Edit context/existing.md projected under cap → ALLOW
# on-disk 100 - old(10) + new(20) = 110
# ---------------------------------------------------------------------------
dir6=$(make_fixture 6)
head -c 100 /dev/zero | tr '\0' 'x' >"$dir6/context/existing.md"
old6="0123456789"
new6=$(head -c 20 /dev/zero | tr '\0' 'y')
payload6=$(jq -n --arg fp "$dir6/context/existing.md" --arg old "$old6" --arg new "$new6" --arg cwd "$dir6" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:$old,new_string:$new},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Edit context/existing.md projected under cap → ALLOW" "0" "$payload6"

# ---------------------------------------------------------------------------
# Test 7: non-curator (developer-phoenix-backend) Write context/big.md 50000 bytes → DENY
# (role-agnostic — ANY role is gated)
# ---------------------------------------------------------------------------
dir7=$(make_fixture 7)
content7=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload7=$(jq -n --arg fp "$dir7/context/big.md" --arg content "$content7" --arg cwd "$dir7" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')

run_test "non-curator Write context/big.md 50000 bytes → DENY (role-agnostic)" "2" "$payload7"

# ---------------------------------------------------------------------------
# Test 8: curator Bash tool with over-cap payload → ALLOW (tool gate)
# ---------------------------------------------------------------------------
dir8=$(make_fixture 8)
payload8=$(jq -n --arg fp "$dir8/context/big.md" --arg cwd "$dir8" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"echo hi",file_path:$fp},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Bash tool with over-cap-shaped payload → ALLOW (tool gate)" "0" "$payload8"

# ---------------------------------------------------------------------------
# Test 9: curator Write lib/foo.ex 50000 bytes → ALLOW (path gate)
# ---------------------------------------------------------------------------
dir9=$(make_fixture 9)
content9=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload9=$(jq -n --arg fp "$dir9/lib/foo.ex" --arg content "$content9" --arg cwd "$dir9" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write lib/foo.ex 50000 bytes → ALLOW (path gate)" "0" "$payload9"

# ---------------------------------------------------------------------------
# Test 10: curator Write context/sub/nested.md 50000 bytes → ALLOW (subdir excluded)
# ---------------------------------------------------------------------------
dir10=$(make_fixture 10)
content10=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload10=$(jq -n --arg fp "$dir10/context/sub/nested.md" --arg content "$content10" --arg cwd "$dir10" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/sub/nested.md 50000 bytes → ALLOW (subdir excluded)" "0" "$payload10"

# ---------------------------------------------------------------------------
# Test 11: curator MultiEdit context/big.md over cap → DENY (sums edits[] deltas)
# ---------------------------------------------------------------------------
dir11=$(make_fixture 11)
big11=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload11=$(jq -n --arg fp "$dir11/context/big.md" --arg new "$big11" --arg cwd "$dir11" '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"a",new_string:$new}]},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator MultiEdit context/big.md over cap → DENY" "2" "$payload11"

# ---------------------------------------------------------------------------
# Test 12: curator Write context/big.md missing/empty content field → ALLOW (fail-open)
# ---------------------------------------------------------------------------
dir12=$(make_fixture 12)
payload12=$(jq -n --arg fp "$dir12/context/big.md" --arg cwd "$dir12" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/big.md missing content field → ALLOW (fail-open)" "0" "$payload12"

# ---------------------------------------------------------------------------
# Test 13: curator Edit context/new.md not yet on disk, new_string over cap → DENY
# on-disk 0 - old(0) + new(50000) = 50000
# ---------------------------------------------------------------------------
dir13=$(make_fixture 13)
new13=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload13=$(jq -n --arg fp "$dir13/context/new.md" --arg new "$new13" --arg cwd "$dir13" '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"",new_string:$new},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Edit context/new.md not on disk, new_string over cap → DENY" "2" "$payload13"

# ---------------------------------------------------------------------------
# Test 14: deny message contains "compress" AND NOT "committer"
# ---------------------------------------------------------------------------
dir14=$(make_fixture 14)
content14=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload14=$(jq -n --arg fp "$dir14/context/big.md" --arg content "$content14" --arg cwd "$dir14" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

stdout14=$(printf '%s' "$payload14" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout14" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    printf '%s' "$stdout14" | grep -qi "compress" &&
    ! printf '%s' "$stdout14" | grep -qi "committer"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny message names compress, not committer\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny message missing compress, or wrongly mentions committer\n  stdout: %s\n' "$stdout14"
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# Test 15: deny message contains the exact projected byte count and "40960-byte (40k) cap"
# ---------------------------------------------------------------------------
dir15=$(make_fixture 15)
content15=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload15=$(jq -n --arg fp "$dir15/context/big.md" --arg content "$content15" --arg cwd "$dir15" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

stdout15=$(printf '%s' "$payload15" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout15" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    printf '%s' "$stdout15" | grep -q "50000" &&
    printf '%s' "$stdout15" | grep -q "40960-byte (40k) cap"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: deny message contains exact byte count and cap substring\n'
    pass=$((pass + 1))
else
    printf 'FAIL: deny message missing byte count or cap substring\n  stdout: %s\n' "$stdout15"
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------------------
# Test 16: FILE_PATH empty → ALLOW (graceful)
# ---------------------------------------------------------------------------
payload16='{"hook_event_name":"PreToolUse","tool_name":"Write","tool_input":{"content":"x"},"agent_type":"context-curator","agent_id":"a","cwd":"/tmp"}'

run_test "FILE_PATH empty → ALLOW (graceful)" "0" "$payload16"

# ---------------------------------------------------------------------------
# Test 17: curator MultiEdit context/small.md under cap → ALLOW
# on-disk 100 - old(10) + new(20) = 110
# ---------------------------------------------------------------------------
dir17=$(make_fixture 17)
head -c 100 /dev/zero | tr '\0' 'x' >"$dir17/context/small.md"
old17="0123456789"
new17=$(head -c 20 /dev/zero | tr '\0' 'y')
payload17=$(jq -n --arg fp "$dir17/context/small.md" --arg old "$old17" --arg new "$new17" --arg cwd "$dir17" '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:$old,new_string:$new}]},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator MultiEdit context/small.md under cap → ALLOW" "0" "$payload17"

# ---------------------------------------------------------------------------
# Test 18: non-curator MultiEdit context/big.md over cap → DENY (role-agnostic MultiEdit)
# ---------------------------------------------------------------------------
dir18=$(make_fixture 18)
big18=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload18=$(jq -n --arg fp "$dir18/context/big.md" --arg new "$big18" --arg cwd "$dir18" '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"a",new_string:$new}]},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')

run_test "non-curator MultiEdit context/big.md over cap → DENY" "2" "$payload18"

# ---------------------------------------------------------------------------
# Test 19: curator Write PROJECT_CONTEXT.md content 50000 bytes → DENY (root doc)
# ---------------------------------------------------------------------------
dir19=$(make_fixture 19)
content19=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload19=$(jq -n --arg fp "$dir19/PROJECT_CONTEXT.md" --arg content "$content19" --arg cwd "$dir19" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write PROJECT_CONTEXT.md content 50000 bytes → DENY (root doc)" "2" "$payload19"

# ---------------------------------------------------------------------------
# Test 20: curator Write codegen/PROJECT_CONTEXT.md content 50000 bytes → DENY (root doc variant)
# ---------------------------------------------------------------------------
dir20=$(make_fixture 20)
content20=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload20=$(jq -n --arg fp "$dir20/codegen/PROJECT_CONTEXT.md" --arg content "$content20" --arg cwd "$dir20" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write codegen/PROJECT_CONTEXT.md content 50000 bytes → DENY (root doc variant)" "2" "$payload20"

# ---------------------------------------------------------------------------
# Test 21: curator Write PROJECT_CONTEXT.md content 100 bytes → ALLOW (root doc under cap)
# ---------------------------------------------------------------------------
dir21=$(make_fixture 21)
content21=$(head -c 100 /dev/zero | tr '\0' 'x')
payload21=$(jq -n --arg fp "$dir21/PROJECT_CONTEXT.md" --arg content "$content21" --arg cwd "$dir21" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write PROJECT_CONTEXT.md content 100 bytes → ALLOW (root doc under cap)" "0" "$payload21"

# ---------------------------------------------------------------------------
# Test 22: curator Write context/sub/nested.md 50000 bytes → ALLOW (nested still excluded, post-widen)
# ---------------------------------------------------------------------------
dir22=$(make_fixture 22)
content22=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload22=$(jq -n --arg fp "$dir22/context/sub/nested.md" --arg content "$content22" --arg cwd "$dir22" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write context/sub/nested.md 50000 bytes → ALLOW (nested still excluded)" "0" "$payload22"

# ---------------------------------------------------------------------------
# Test 23: outside a git repo → ALLOW (fail-open)
# ---------------------------------------------------------------------------
nogit_dir="/tmp/curator-size-test-nogit"
rm -rf "$nogit_dir"
mkdir -p "$nogit_dir"
FIXTURES+=("$nogit_dir")
content23=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload23=$(jq -n --arg fp "$nogit_dir/PROJECT_CONTEXT.md" --arg content "$content23" --arg cwd "$nogit_dir" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "outside a git repo → ALLOW (fail-open)" "0" "$payload23"

# ---------------------------------------------------------------------------
# Test 24: CLAUDE.md / AGENTS.md over cap → ALLOW (deliberately not gated)
# ---------------------------------------------------------------------------
dir24=$(make_fixture 24)
content24=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload24=$(jq -n --arg fp "$dir24/CLAUDE.md" --arg content "$content24" --arg cwd "$dir24" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

run_test "curator Write CLAUDE.md content 50000 bytes → ALLOW (not gated)" "0" "$payload24"

# ---------------------------------------------------------------------------
# Test 25: PROJECT_CONTEXT.md over-cap deny message does NOT say "add the
# matching PROJECT_CONTEXT.md row" — that advice is incoherent when the
# denied file IS PROJECT_CONTEXT.md.
# ---------------------------------------------------------------------------
dir25=$(make_fixture 25)
content25=$(head -c 50000 /dev/zero | tr '\0' 'x')
payload25=$(jq -n --arg fp "$dir25/PROJECT_CONTEXT.md" --arg content "$content25" --arg cwd "$dir25" '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')

stdout25=$(printf '%s' "$payload25" | env -u CLAUDE_ROLE -u PI_ROLE bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout25" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"' &&
    ! printf '%s' "$stdout25" | grep -q "add the matching PROJECT_CONTEXT.md"; then
    [ -n "${VERBOSE:-}" ] && printf 'PASS: root-doc deny message does not tell writer to add a PROJECT_CONTEXT.md row\n'
    pass=$((pass + 1))
else
    printf 'FAIL: root-doc deny message incoherently references adding a PROJECT_CONTEXT.md row\n  stdout: %s\n' "$stdout25"
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
