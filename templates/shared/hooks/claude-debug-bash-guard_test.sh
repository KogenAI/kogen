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
        printf 'PASS: %s\n' "$desc"
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

# 1: rm -rf blocked in debug
run_test "rm -rf blocked in debug role" "2" \
    "$(mk 'rm -rf /tmp/foo')" "debug"

# 2: rm -r blocked in debug
run_test "rm -r blocked in debug role" "2" \
    "$(mk 'rm -r build/')" "debug"

# 3: mix ecto.migrate blocked
run_test "mix ecto.migrate blocked in debug role" "2" \
    "$(mk 'mix ecto.migrate')" "debug"

# 4: mix ecto.rollback blocked
run_test "mix ecto.rollback blocked in debug role" "2" \
    "$(mk 'mix ecto.rollback')" "debug"

# 5: mix ecto.drop blocked
run_test "mix ecto.drop blocked in debug role" "2" \
    "$(mk 'mix ecto.drop')" "debug"

# 6: git commit blocked
run_test "git commit blocked in debug role" "2" \
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

# 29b: rm -rf blocked in refactor role
run_test "rm -rf blocked in refactor role" "2" \
    "$(mk 'rm -rf /tmp/foo')" "refactor"

# 29c: git push blocked in refactor role
run_test "git push blocked in refactor role" "2" \
    "$(mk 'git push origin main')" "refactor"

# 29d: ls allowed in refactor role
run_test "ls allowed in refactor role" "0" \
    "$(mk 'ls -la /tmp')" "refactor"

# 29e: curl -X POST blocked in refactor role
run_test "curl -X POST blocked in refactor role" "2" \
    "$(mk 'curl -X POST https://api.example.com/users')" "refactor"

# 30: rm -rf still allowed in unrelated role (build)
run_test "rm -rf allowed in build role (guard inactive)" "0" \
    "$(mk 'rm -rf _build')" "build"

# PI_ROLE parity tests (run_test uses CLAUDE_ROLE env var; use separate helper for PI_ROLE/CODEX_ROLE)

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
        printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# 31: PI_ROLE=debug + rm -rf → deny
run_test_env "PI_ROLE=debug rm -rf blocked" "2" \
    "$(mk 'rm -rf /tmp/foo')" "PI_ROLE" "debug"

# 32: PI_ROLE=debug + ls → allow
run_test_env "PI_ROLE=debug ls allowed" "0" \
    "$(mk 'ls -la /tmp')" "PI_ROLE" "debug"

# 33: PI_ROLE=shape + git push → deny
run_test_env "PI_ROLE=shape git push blocked" "2" \
    "$(mk 'git push origin main')" "PI_ROLE" "shape"

# 34: PI_ROLE=shape + ls → allow
run_test_env "PI_ROLE=shape ls allowed" "0" \
    "$(mk 'ls -la /tmp')" "PI_ROLE" "shape"

# 34b: PI_ROLE=refactor + git push → deny
run_test_env "PI_ROLE=refactor git push blocked" "2" \
    "$(mk 'git push origin main')" "PI_ROLE" "refactor"

# 34c: PI_ROLE=refactor + ls → allow
run_test_env "PI_ROLE=refactor ls allowed" "0" \
    "$(mk 'ls -la /tmp')" "PI_ROLE" "refactor"

# 35: CODEX_ROLE=debug + rm -rf → deny
run_test_env "CODEX_ROLE=debug rm -rf blocked" "2" \
    "$(mk 'rm -rf /tmp/foo')" "CODEX_ROLE" "debug"

# 36: CODEX_ROLE=debug + ls → allow
run_test_env "CODEX_ROLE=debug ls allowed" "0" \
    "$(mk 'ls -la /tmp')" "CODEX_ROLE" "debug"

# 37: CODEX_ROLE=shape + git push → deny
run_test_env "CODEX_ROLE=shape git push blocked" "2" \
    "$(mk 'git push origin main')" "CODEX_ROLE" "shape"

# 38: CODEX_ROLE=shape + ls → allow
run_test_env "CODEX_ROLE=shape ls allowed" "0" \
    "$(mk 'ls -la /tmp')" "CODEX_ROLE" "shape"

# 38b: CODEX_ROLE=refactor + git push → deny
run_test_env "CODEX_ROLE=refactor git push blocked" "2" \
    "$(mk 'git push origin main')" "CODEX_ROLE" "refactor"

# 38c: CODEX_ROLE=refactor + ls → allow
run_test_env "CODEX_ROLE=refactor ls allowed" "0" \
    "$(mk 'ls -la /tmp')" "CODEX_ROLE" "refactor"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
