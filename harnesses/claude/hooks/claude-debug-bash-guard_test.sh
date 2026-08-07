#!/bin/bash
# claude-debug-bash-guard_test.sh — unit tests for claude-debug-bash-guard.sh
#
# Tests:
#   1:  rm -rf path → deny (debug role)
#   2:  rm -r path → deny (debug role)
#   3:  mix ecto.migrate → deny (debug role)
#   4:  mix ecto.rollback → deny (debug role)
#   5:  mix ecto.drop → deny (debug role)
#   6:  git commit → deny (debug role)
#   7:  git push → deny (debug role)
#   8:  git reset --hard → deny (debug role)
#   9:  mix deps.get → deny (debug role)
#   10: mix run priv/repo/seeds → deny (debug role)
#   11: TRUNCATE TABLE via psql → deny (debug role)
#   12: rm -rf path in non-debug role → allow
#   13: non-Bash tool → allow
#   14: read-only command (ls) in debug role → allow
#   (refactor tests removed — refactor mode dropped)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/claude-debug-bash-guard.sh"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local role="${4:-}"

    local stdout
    stdout=$(printf '%s' "$input" | CLAUDE_ROLE="$role" bash "$GUARD" 2>/dev/null || true)

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

DEBUG_AGENT='{"hook_event_name":"PreToolUse","tool_name":"Bash","agent_type":"","agent_id":"a"}'

mk() {
    local cmd="$1"
    printf '%s' "$DEBUG_AGENT" | jq --arg cmd "$cmd" '.tool_input = {command: $cmd}'
}

# mk_agent — like mk, but sets agent_type (for spike-builder sandbox-bypass tests)
mk_agent() {
    local cmd="$1"
    local agent_type="$2"
    printf '%s' "$DEBUG_AGENT" | jq --arg cmd "$cmd" --arg at "$agent_type" \
        '.tool_input = {command: $cmd} | .agent_type = $at | .agent_id = "abc123"'
}

# 1: rm -rf blocked in debug
run_test "rm -rf blocked in debug role" "2" \
    "$(mk 'rm -rf /tmp/foo')" "debug"

# 2: rm -r blocked in debug
run_test "rm -r blocked in debug role" "2" \
    "$(mk 'rm -r build/')" "debug"

# 2a: rm -fr (reversed cluster) blocked in debug
run_test "rm -fr blocked in debug role" "2" \
    "$(mk 'rm -fr build/')" "debug"

# 2b: rm --recursive blocked in debug
run_test "rm --recursive blocked in debug role" "2" \
    "$(mk 'rm --recursive build/')" "debug"

# 2c: rm --force allowed in debug (no r-cluster; long-flag false-positive fix)
run_test "rm --force allowed in debug role (no recursive flag)" "0" \
    "$(mk 'rm --force /tmp/foo')" "debug"

# 2d: rm --verbose allowed in debug (no r-cluster; long-flag false-positive fix)
run_test "rm --verbose allowed in debug role (no recursive flag)" "0" \
    "$(mk 'rm --verbose /tmp/foo')" "debug"

# 3: mix ecto.migrate blocked
run_test "mix ecto.migrate blocked in debug role" "2" \
    "$(mk 'mix ecto.migrate')" "debug"

# 4: mix ecto.rollback blocked
run_test "mix ecto.rollback blocked in debug role" "2" \
    "$(mk 'mix ecto.rollback')" "debug"

# 5: mix ecto.drop blocked
run_test "mix ecto.drop blocked in debug role" "2" \
    "$(mk 'mix ecto.drop')" "debug"

# 6: git commit — now ALLOWED here (pre-commit-guard owns the deny; this
# hook dropped its redundant duplicate clause per hook-hygiene-sweep)
run_test "git commit allowed in debug role (pre-commit-guard owns deny)" "0" \
    "$(mk 'git commit -m "fix"')" "debug"

# 7: git push blocked
run_test "git push blocked in debug role" "2" \
    "$(mk 'git push origin main')" "debug"

# 8: git reset --hard blocked
run_test "git reset --hard blocked in debug role" "2" \
    "$(mk 'git reset --hard HEAD~1')" "debug"

# 9: mix deps.get blocked
run_test "mix deps.get blocked in debug role" "2" \
    "$(mk 'mix deps.get')" "debug"

# 10: mix run seeds blocked
run_test "mix run seeds blocked in debug role" "2" \
    "$(mk 'mix run priv/repo/seeds.exs')" "debug"

# 11: TRUNCATE TABLE blocked
run_test "TRUNCATE TABLE via psql blocked in debug role" "2" \
    "$(mk 'psql $DATABASE_URL -c "TRUNCATE TABLE users;"')" "debug"

# 12: rm -rf in non-debug role allowed (build role)
run_test "rm -rf allowed in non-debug role" "0" \
    "$(mk 'rm -rf _build')" "build"

# 13: non-Bash tool allowed even in debug
run_test "non-Bash tool allowed in debug role" "0" \
    '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/tmp/foo.txt"},"agent_type":"","agent_id":"a"}' "debug"

# 14: read-only ls allowed in debug
run_test "ls allowed in debug role" "0" \
    "$(mk 'ls -la /tmp')" "debug"

# 15: curl -X DELETE blocked in debug
run_test "curl -X DELETE blocked in debug role" "2" \
    "$(mk 'curl -X DELETE https://api.example.com/users/1')" "debug"

# 16: curl -X POST blocked in debug
run_test "curl -X POST blocked in debug role" "2" \
    "$(mk 'curl -X POST -d @body.json https://api.example.com/users')" "debug"

# 17: docker run blocked in debug
run_test "docker run blocked in debug role" "2" \
    "$(mk 'docker run -it ubuntu bash')" "debug"

# 18: systemctl restart blocked in debug
run_test "systemctl restart blocked in debug role" "2" \
    "$(mk 'systemctl restart app.service')" "debug"

# 19: kill blocked in debug
run_test "kill blocked in debug role" "2" \
    "$(mk 'kill -9 12345')" "debug"

# 20: npm install blocked in debug
run_test "npm install blocked in debug role" "2" \
    "$(mk 'npm install express')" "debug"

# 21: pip install blocked in debug
run_test "pip install blocked in debug role" "2" \
    "$(mk 'pip install requests')" "debug"

# 22: brew install blocked in debug
run_test "brew install blocked in debug role" "2" \
    "$(mk 'brew install jq')" "debug"

# 23: curl GET (read-only inspection) allowed in debug
run_test "curl GET allowed in debug role" "0" \
    "$(mk 'curl https://api.example.com/status')" "debug"

# 24: docker ps (read-only) allowed in debug
run_test "docker ps allowed in debug role" "0" \
    "$(mk 'docker ps')" "debug"

# 25: systemctl status (read-only) allowed in debug
run_test "systemctl status allowed in debug role" "0" \
    "$(mk 'systemctl status app.service')" "debug"

# 26: rm -rf blocked in shape role
run_test "rm -rf blocked in shape role" "2" \
    "$(mk 'rm -rf /tmp/foo')" "shape"

# 27: git push blocked in shape role
run_test "git push blocked in shape role" "2" \
    "$(mk 'git push origin main')" "shape"

# 28: ls allowed in shape role
run_test "ls allowed in shape role" "0" \
    "$(mk 'ls -la /tmp')" "shape"

# 29: curl -X POST blocked in shape role
run_test "curl -X POST blocked in shape role" "2" \
    "$(mk 'curl -X POST https://api.example.com/users')" "shape"

# 30: rm -rf still allowed in unrelated role (build)
run_test "rm -rf allowed in build role (guard inactive)" "0" \
    "$(mk 'rm -rf _build')" "build"

# --- Mention-vs-invocation tests (this guard's own coverage of its central
# claim: a forbidden token appearing inside a grep pattern, echo string, or
# quoted/commented text is a MENTION, never an invocation, and must be
# ALLOWED — only a real command-word invocation is DENIED). ---

# 35: grep -c kill (mention of "kill" in a grep pattern) allowed in debug
run_test "grep mentioning 'kill' allowed in debug role" "0" \
    "$(mk 'grep -c kill foo.sh')" "debug"

# 36: echo mentioning "git push" allowed in debug
run_test "echo mentioning 'git push' allowed in debug role" "0" \
    "$(mk 'echo "git push"')" "debug"

# 37: grep mentioning "rm -rf x" in a search pattern allowed in debug
run_test "grep mentioning 'rm -rf x' allowed in debug role" "0" \
    "$(mk 'grep -rn "rm -rf x" notes.md')" "debug"

# 38: grep mentioning "git push" in docs allowed in debug
run_test "grep mentioning 'git push' in docs allowed in debug role" "0" \
    "$(mk 'grep -n "git push" docs.md')" "debug"

# 39: echo mentioning "kill" (tree-kill teardown) allowed in debug
run_test "echo mentioning tree-kill teardown allowed in debug role" "0" \
    "$(mk 'echo "tree-kill teardown"')" "debug"

# 40: a REAL invocation nested inside bash -c is still denied (proves the
# mention-allow fix did not regress the wrapped/nested-invocation case)
run_test "bash -c 'kill 123' still blocked in debug role" "2" \
    "$(mk "bash -c 'kill 123'")" "debug"

# 41: a REAL rm -rf invocation is still denied alongside mention-allows above
run_test "rm -rf still blocked in debug role (regression check)" "2" \
    "$(mk 'rm -rf /tmp/foo')" "debug"

# 42: a quoted grep command with an escaped double-quote inside the pattern
# is allowed, and does NOT produce a phantom deny naming a verb the command
# never contains (this pitch's core fix — the parser must not mis-read \"
# as closing the string and falling into fail-closed).
escaped_quote_stdout=$(printf '%s' "$(mk 'grep -o "{% include \"[^\"]*\"" tmpl | sed -n 1p')" |
    CLAUDE_ROLE="debug" bash "$GUARD" 2>/dev/null || true)
if printf '%s' "$escaped_quote_stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: quoted grep with escaped quotes allowed in debug role — got deny: %s\n' \
        "$escaped_quote_stdout"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: quoted grep with escaped quotes allowed in debug role\n'
    pass=$((pass + 1))
fi
if printf '%s' "$escaped_quote_stdout" | grep -qE '(recursive rm|git push) forbidden'; then
    printf 'FAIL: quoted grep with escaped quotes named a phantom verb: %s\n' \
        "$escaped_quote_stdout"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: quoted grep with escaped quotes names no phantom verb\n'
    pass=$((pass + 1))
fi

# 43: a genuinely unbalanced quote is denied with the honest "could not
# parse" message, never a borrowed rule name (e.g. "recursive rm forbidden")
# for a command that never actually invoked that rule's verb.
unparseable_stdout=$(printf '%s' "$(mk "echo 'unterminated")" |
    CLAUDE_ROLE="debug" bash "$GUARD" 2>/dev/null || true)
if ! printf '%s' "$unparseable_stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
    printf 'FAIL: genuinely unbalanced quote must still deny (fail-closed) — got: %s\n' \
        "$unparseable_stdout"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: genuinely unbalanced quote denies (fail-closed)\n'
    pass=$((pass + 1))
fi
if ! printf '%s' "$unparseable_stdout" | grep -q 'could not parse this command'; then
    printf 'FAIL: unparseable command must name itself honestly, not borrow a rule message: %s\n' \
        "$unparseable_stdout"
    fail=$((fail + 1))
else
    [ -n "${VERBOSE:-}" ] && printf 'PASS: unparseable command names itself honestly\n'
    pass=$((pass + 1))
fi

# 44: bash -n against a script whose body legitimately contains a forbidden
# verb (e.g. "git push" inside a comment) is ALLOWED — a syntax-only check
# never executes the file, so the referenced body must not be appended via
# indirection (the fix this pitch makes to expand_command_indirection).
NDIR="$(mktemp -d)"
trap 'rm -rf "$NDIR"' EXIT
printf '#!/bin/bash\n# see also: git push origin main\necho hi\n' >"$NDIR/danger.sh"
run_test "bash -n against a script mentioning 'git push' in a comment allows" "0" \
    "$(mk "bash -n $NDIR/danger.sh")" "debug"
rm -rf "$NDIR"

# npm i (alias for npm install) blocked in debug role — package-install
# pattern must catch the short alias, not just the long form.
run_test "npm i (install alias) blocked in debug role" "2" \
    "$(mk 'npm i express')" "debug"

run_test "npm install blocked in debug role (still)" "2" \
    "$(mk 'npm install express')" "debug"

run_test "npm info (not an install alias) allows in debug role" "0" \
    "$(mk 'npm info express')" "debug"

# spike-builder sandbox bypass — active under BOTH debug and shape (this
# guard's role gate at the top admits both; spike-builder is reachable from
# both per operator-subagent-allowlist.sh: shape via its explicit
# {Explore, spike-builder} allowlist, debug via the generic "project
# subagents allowed everywhere" rule — see operator-subagent-allowlist_test.sh
# "debug + spike-builder allowed"). AGENT_TYPE=spike-builder bypasses the
# verb denies this file otherwise enforces, so it can build and probe a
# throwaway feasibility spike confined to codegen/pitches/ and /tmp/
# (confinement enforced by orchestrator-no-source-edit.sh, not this file).
run_test "spike-builder npm install allows in shape mode" "0" \
    "$(mk_agent 'npm install express' 'spike-builder')" "shape"

run_test "spike-builder kill allows in shape mode" "0" \
    "$(mk_agent 'kill 123' 'spike-builder')" "shape"

run_test "spike-builder rm -rf /tmp/spike allows in shape mode" "0" \
    "$(mk_agent 'rm -rf /tmp/spike' 'spike-builder')" "shape"

run_test "spike-builder curl -X POST allows in shape mode" "0" \
    "$(mk_agent 'curl -X POST http://localhost:4000/probe' 'spike-builder')" "shape"

run_test "spike-builder docker run allows in shape mode" "0" \
    "$(mk_agent 'docker run --rm node:20' 'spike-builder')" "shape"

# spike-builder still cannot escape the sandbox — git push / reset --hard /
# mix ecto.* / destructive SQL stay denied even for the builder.
run_test "spike-builder git push denies in shape mode" "2" \
    "$(mk_agent 'git push' 'spike-builder')" "shape"

run_test "spike-builder git reset --hard denies in shape mode" "2" \
    "$(mk_agent 'git reset --hard' 'spike-builder')" "shape"

run_test "spike-builder mix ecto.drop denies in shape mode" "2" \
    "$(mk_agent 'mix ecto.drop' 'spike-builder')" "shape"

run_test "spike-builder destructive SQL (TRUNCATE) denies in shape mode" "2" \
    "$(mk_agent 'psql -c \"TRUNCATE TABLE users\"' 'spike-builder')" "shape"

# Same bypass, same sandbox, under debug mode — spike-builder is reachable
# from debug too (debug has no subagent allowlist restriction), so the
# sandbox bypass here must fire identically rather than being shape-only.
run_test "spike-builder npm install allows in debug mode" "0" \
    "$(mk_agent 'npm install express' 'spike-builder')" "debug"

run_test "spike-builder rm -rf /tmp/spike allows in debug mode" "0" \
    "$(mk_agent 'rm -rf /tmp/spike' 'spike-builder')" "debug"

run_test "spike-builder git push denies in debug mode" "2" \
    "$(mk_agent 'git push' 'spike-builder')" "debug"

run_test "spike-builder mix ecto.drop denies in debug mode" "2" \
    "$(mk_agent 'mix ecto.drop' 'spike-builder')" "debug"

# the shaper itself (no spike-builder agent_type) is unaffected — still
# denied on the same verbs, byte-for-byte with pre-existing behavior.
run_test "shaper (no agent_type) npm install still denies in shape mode" "2" \
    "$(mk 'npm install express')" "shape"

run_test "shaper (no agent_type) kill still denies in shape mode" "2" \
    "$(mk 'kill 123')" "shape"

run_test_env() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local env_var="$4"
    local role_val="$5"

    local stdout
    stdout=$(printf '%s' "$input" | env "$env_var=$role_val" bash "$GUARD" 2>/dev/null || true)

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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
