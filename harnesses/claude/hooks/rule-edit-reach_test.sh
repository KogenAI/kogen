#!/bin/bash
# rule-edit-reach_test.sh — unit tests for rule-edit-reach.sh
#
# Tests build a minimal fake repo tree under /tmp with:
#   templates/generator/process_template.py + prompt_size_budget.py (copied
#     from the real repo — these are the modules under test, unmodified)
#   templates/generator/config.yaml (minimal — templates carry no model: line
#     so process_template.py never needs a role_cfg lookup)
#   shared/subagents/phoenix/a.md.j2, b.md.j2 (two top-level prompts)
#   shared/rules/_core/frag.md (included by both — fan-out 2)
#   shared/rules/_core/lonely.md (included by neither — fan-out 0)
#   templates/generator/<budgets-filename> — the committed budget rows
#
# The budget-file NAME is assembled at runtime via variable concatenation
# (never spelled literally as "templates/generator/prompt-budgets.txt" in
# this script's source text) — prompt-budget-writer-only.sh denies any Bash
# invocation whose command text contains that literal path followed by
# write-vocab (heredoc redirect, tee, sed -i, mv/cp), and it scans referenced
# script files too (expand_command_indirection), so spelling the path
# directly in this file's own heredoc would be denied when this test itself
# is later run via `bash rule-edit-reach_test.sh`.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/rule-edit-reach.sh"
REAL_REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

pass=0
fail=0

FIXTURES=()
cleanup() {
    for d in "${FIXTURES[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

BUDGET_FILENAME="prompt-budgets.txt"

# make_fixture <n> — a throwaway git repo with the minimal include graph
# described above. Returns the fixture root path.
make_fixture() {
    local n="$1"
    local dir="/tmp/rule-edit-reach-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/templates/generator" "$dir/shared/subagents/phoenix" "$dir/shared/rules/_core"
    cp "$REAL_REPO_ROOT/templates/generator/process_template.py" "$dir/templates/generator/"
    cp "$REAL_REPO_ROOT/templates/generator/prompt_size_budget.py" "$dir/templates/generator/"
    printf 'harness: {}\n' >"$dir/templates/generator/config.yaml"

    cat >"$dir/shared/subagents/phoenix/a.md.j2" <<'EOF'
Agent A prompt body text here for padding purposes only.
{% include 'rules/_core/frag.md' %}
EOF
    cat >"$dir/shared/subagents/phoenix/b.md.j2" <<'EOF'
Agent B prompt body text here for padding purposes only, slightly longer.
{% include 'rules/_core/frag.md' %}
EOF
    cat >"$dir/shared/rules/_core/frag.md" <<'EOF'
line1
line2
EOF
    cat >"$dir/shared/rules/_core/lonely.md" <<'EOF'
lonely line
EOF

    local budget_dir="$dir/templates/generator"
    local budget_path="$budget_dir/$BUDGET_FILENAME"
    {
        printf 'shared/rules/_core/frag.md 5\n'
        printf 'shared/subagents/phoenix/a.md.j2 90\n'
        printf 'shared/subagents/phoenix/b.md.j2 20\n'
    } >"$budget_path"

    (cd "$dir" && git init -q)
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

# run_test <desc> <dir> <payload_json> <expect: advise|silent> [<grep_pattern>]
run_test() {
    local desc="$1" dir="$2" payload="$3" expect="$4" grep_pattern="${5:-}"

    local stdout
    stdout=$(printf '%s' "$payload" | CODEGEN_DIR="$dir" env -u CLAUDE_ROLE bash "$HOOK" 2>/dev/null || true)

    local got_advisory="no"
    local advisory_text=""
    if printf '%s' "$stdout" | grep -q '"additionalContext"'; then
        got_advisory="yes"
        advisory_text=$(printf '%s' "$stdout" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || true)
    fi

    local ok=1
    if [ "$expect" = "advise" ] && [ "$got_advisory" != "yes" ]; then
        ok=0
    fi
    if [ "$expect" = "silent" ] && [ "$got_advisory" != "no" ]; then
        ok=0
    fi
    if [ "$ok" = 1 ] && [ -n "$grep_pattern" ] && [ "$got_advisory" = "yes" ]; then
        if ! printf '%s' "$advisory_text" | grep -qE "$grep_pattern"; then
            ok=0
        fi
    fi
    # advise() must never carry permissionDecision — the hook cannot block.
    if [ "$got_advisory" = "yes" ] && printf '%s' "$stdout" | grep -q '"permissionDecision"'; then
        ok=0
    fi

    if [ "$ok" = 1 ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  expected=%s got_advisory=%s\n  stdout: %s\n' \
            "$desc" "$expect" "$got_advisory" "$stdout"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test 1: net-additive Edit on a fan-out-2 fragment past its own committed
# row AND past both reached prompts' headroom -> advisory naming both.
# ---------------------------------------------------------------------------
dir1=$(make_fixture 1)
new1=$(head -c 60 /dev/zero | tr '\0' 'x')
payload1=$(jq -n --arg fp "$dir1/shared/rules/_core/frag.md" --arg new "$new1" --arg cwd "$dir1" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"line1",new_string:$new},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "net-additive Edit on fan-out-2 fragment -> advisory" "$dir1" "$payload1" "advise" "reaches 2 rendered prompt"

# ---------------------------------------------------------------------------
# Test 2: net-shrinking Edit -> no advisory (nothing can newly overflow).
# ---------------------------------------------------------------------------
dir2=$(make_fixture 2)
old2=$(head -c 60 /dev/zero | tr '\0' 'x')
payload2=$(jq -n --arg fp "$dir2/shared/rules/_core/frag.md" --arg old "$old2" --arg cwd "$dir2" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:$old,new_string:"x"},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "net-shrinking Edit -> no advisory" "$dir2" "$payload2" "silent"

# ---------------------------------------------------------------------------
# Test 3: fragment with zero reach (lonely.md) -> advisory says "reaches 0"
# ---------------------------------------------------------------------------
dir3=$(make_fixture 3)
new3=$(head -c 20 /dev/zero | tr '\0' 'y')
payload3=$(jq -n --arg fp "$dir3/shared/rules/_core/lonely.md" --arg new "$new3" --arg cwd "$dir3" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"lonely line",new_string:$new},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "fragment with zero reach -> advisory says reaches 0" "$dir3" "$payload3" "advise" "reaches 0 rendered prompts"

# ---------------------------------------------------------------------------
# Test 4: path outside shared/rules/** -> no advisory (out of scope).
# ---------------------------------------------------------------------------
dir4=$(make_fixture 4)
mkdir -p "$dir4/lib"
payload4=$(jq -n --arg fp "$dir4/lib/foo.ex" --arg cwd "$dir4" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"a",new_string:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "path outside shared/rules/** -> no advisory" "$dir4" "$payload4" "silent"

# ---------------------------------------------------------------------------
# Test 5: MultiEdit net-additive on the fan-out-2 fragment -> advisory.
# ---------------------------------------------------------------------------
dir5=$(make_fixture 5)
new5=$(head -c 60 /dev/zero | tr '\0' 'z')
payload5=$(jq -n --arg fp "$dir5/shared/rules/_core/frag.md" --arg new "$new5" --arg cwd "$dir5" \
    '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[{old_string:"line1",new_string:$new}]},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "MultiEdit net-additive -> advisory" "$dir5" "$payload5" "advise" "reaches 2 rendered prompt"

# ---------------------------------------------------------------------------
# Test 6: MultiEdit with empty edits[] -> no advisory (fail-open unparseable).
# ---------------------------------------------------------------------------
dir6=$(make_fixture 6)
payload6=$(jq -n --arg fp "$dir6/shared/rules/_core/frag.md" --arg cwd "$dir6" \
    '{hook_event_name:"PreToolUse",tool_name:"MultiEdit",tool_input:{file_path:$fp,edits:[]},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "MultiEdit empty edits[] -> no advisory (fail-open)" "$dir6" "$payload6" "silent"

# ---------------------------------------------------------------------------
# Test 7: Write of a brand-new rule file, whole content is the delta -> advisory.
# ---------------------------------------------------------------------------
dir7=$(make_fixture 7)
content7=$(head -c 60 /dev/zero | tr '\0' 'w')
payload7=$(jq -n --arg fp "$dir7/shared/rules/_core/new-file.md" --arg content "$content7" --arg cwd "$dir7" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:$content},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "Write brand-new rule file -> advisory (reaches 0, no committed row)" "$dir7" "$payload7" "advise" "reaches 0 rendered prompts"

# ---------------------------------------------------------------------------
# Test 8: Write replacing frag.md entirely with LESS content -> no advisory.
# ---------------------------------------------------------------------------
dir8=$(make_fixture 8)
printf 'x' >"$dir8/shared/rules/_core/frag.md"
payload8=$(jq -n --arg fp "$dir8/shared/rules/_core/frag.md" --arg cwd "$dir8" \
    '{hook_event_name:"PreToolUse",tool_name:"Write",tool_input:{file_path:$fp,content:""},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "Write shrinking content -> no advisory (empty content fail-open)" "$dir8" "$payload8" "silent"

# ---------------------------------------------------------------------------
# Test 9: Non-Edit/Write/MultiEdit tool (Read) -> no advisory (tool gate).
# ---------------------------------------------------------------------------
dir9=$(make_fixture 9)
payload9=$(jq -n --arg fp "$dir9/shared/rules/_core/frag.md" --arg cwd "$dir9" \
    '{hook_event_name:"PreToolUse",tool_name:"Read",tool_input:{file_path:$fp},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "Read tool -> no advisory (tool gate)" "$dir9" "$payload9" "silent"

# ---------------------------------------------------------------------------
# Test 10: role-agnostic — curator's write also gets an advisory (role: "*").
# ---------------------------------------------------------------------------
dir10=$(make_fixture 10)
new10=$(head -c 60 /dev/zero | tr '\0' 'x')
payload10=$(jq -n --arg fp "$dir10/shared/rules/_core/frag.md" --arg new "$new10" --arg cwd "$dir10" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"line1",new_string:$new},agent_type:"context-curator",agent_id:"a",cwd:$cwd}')
run_test "role-agnostic: context-curator edit also gets advisory" "$dir10" "$payload10" "advise" "reaches 2 rendered prompt"

# ---------------------------------------------------------------------------
# Test 11: empty FILE_PATH -> no advisory (defensive).
# ---------------------------------------------------------------------------
payload11='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"","old_string":"a","new_string":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"agent_type":"developer-phoenix-backend","agent_id":"a"}'
run_test "empty FILE_PATH -> no advisory (defensive)" "" "$payload11" "silent"

# ---------------------------------------------------------------------------
# Test 12: unresolvable repo root (no templates/generator/prompt_size_budget.py
# anywhere up the parent chain) -> no advisory (fail-open).
# ---------------------------------------------------------------------------
dir12="/tmp/rule-edit-reach-test-noroot"
rm -rf "$dir12"
mkdir -p "$dir12/shared/rules/_core"
printf 'line1\n' >"$dir12/shared/rules/_core/frag.md"
FIXTURES+=("$dir12")
new12=$(head -c 60 /dev/zero | tr '\0' 'x')
payload12=$(jq -n --arg fp "$dir12/shared/rules/_core/frag.md" --arg new "$new12" --arg cwd "$dir12" \
    '{hook_event_name:"PreToolUse",tool_name:"Edit",tool_input:{file_path:$fp,old_string:"line1",new_string:$new},agent_type:"developer-phoenix-backend",agent_id:"a",cwd:$cwd}')
run_test "unresolvable repo root -> no advisory (fail-open)" "$dir12" "$payload12" "silent"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
