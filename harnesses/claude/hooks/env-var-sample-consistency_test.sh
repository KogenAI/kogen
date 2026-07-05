#!/bin/bash
# env-var-sample-consistency_test.sh — unit tests for env-var-sample-consistency.sh
# (SubagentStop hook for developer-phoenix-backend | developer-phoenix-frontend)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${GUARD_OVERRIDE:-$SCRIPT_DIR/env-var-sample-consistency.sh}"

pass=0
fail=0

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"
    local test_dir="$4"

    local stdout
    stdout=$(cd "$test_dir" && printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

    local outcome
    if printf '%s' "$stdout" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        outcome="block"
    else
        outcome="allow"
    fi

    if [ "$outcome" = "$expected" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s
  stdout: %s
' "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

(
    cd "$TMP_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git config commit.gpgsign false
    printf 'config :app, key: System.get_env("EXISTING_VAR")\n' >runtime.exs
    printf 'export EXISTING_VAR=\n' >.env.sample
    printf 'EXISTING_VAR=\n' >.env.prod.sample
    git add runtime.exs .env.sample .env.prod.sample
    git commit -q -m "init"
)

payload() {
    local agent_type="$1"
    local stop_active="$2"
    printf '{"hook_event_name":"SubagentStop","agent_type":"%s","cwd":"%s","session_id":"s1","stop_hook_active":%s}' \
        "$agent_type" "$TMP_DIR" "$stop_active"
}

# Test 1: committer — not gated
FIXTURE_COMMITTER=$(payload "committer" "false")
run_test "committer is not gated" "allow" "$FIXTURE_COMMITTER" "$TMP_DIR"

# Test 2: developer, stop_hook_active=true — loop guard allows
FIXTURE_LOOP=$(payload "developer-phoenix-backend" "true")
run_test "stop_hook_active loop guard allows" "allow" "$FIXTURE_LOOP" "$TMP_DIR"

# Test 3: developer, working-tree diff adds System.get_env("NEW_VAR") to a
# tracked file, samples untouched — BLOCK
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, key2: System.get_env("NEW_VAR")\n' >runtime.exs
)
FIXTURE_NEW_VAR=$(payload "developer-phoenix-backend" "false")
run_test "developer working-tree diff adds undocumented var blocks" "block" "$FIXTURE_NEW_VAR" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- runtime.exs)

# Test 4: developer, same diff but both sample files declare NEW_VAR — allow
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, key2: System.get_env("NEW_VAR")\n' >runtime.exs
    printf 'export NEW_VAR=\n' >>.env.sample
    printf 'NEW_VAR=\n' >>.env.prod.sample
)
FIXTURE_WITH_SAMPLES=$(payload "developer-phoenix-backend" "false")
run_test "developer working-tree diff with both samples declared allows" "allow" "$FIXTURE_WITH_SAMPLES" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- runtime.exs .env.sample .env.prod.sample)

# Test 5: developer, argless System.get_env() — allow
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env()\n' >runtime.exs
)
FIXTURE_ARGLESS=$(payload "developer-phoenix-backend" "false")
run_test "argless System.get_env() allows" "allow" "$FIXTURE_ARGLESS" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- runtime.exs)

# Test 6: developer, System.get_env("EXISTING_VAR") already in samples — allow
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, other: 1\n' >runtime.exs
)
FIXTURE_DOCUMENTED=$(payload "developer-phoenix-backend" "false")
run_test "already-documented var read allows" "allow" "$FIXTURE_DOCUMENTED" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- runtime.exs)

# Test 7: developer, UNSTAGED edit adding System.get_env("UNSTAGED_VAR")
# (no `git add`), samples untouched — BLOCK. Proves working-tree source, not
# staged-only.
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, key2: System.get_env("UNSTAGED_VAR")\n' >runtime.exs
)
FIXTURE_UNSTAGED=$(payload "developer-phoenix-backend" "false")
run_test "unstaged working-tree edit with undocumented var blocks" "block" "$FIXTURE_UNSTAGED" "$TMP_DIR"
(cd "$TMP_DIR" && git checkout -- runtime.exs)

# Test 8: developer, diff only REMOVES a System.get_env("GONE_VAR") line — allow
(
    cd "$TMP_DIR"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\nconfig :app, key2: System.get_env("GONE_VAR")\n' >runtime.exs
    git add runtime.exs
    git commit -q -m "add gone var read"
    printf 'config :app, key: System.get_env("EXISTING_VAR")\n' >runtime.exs
)
FIXTURE_REMOVED_ONLY=$(payload "developer-phoenix-backend" "false")
run_test "removed-only System.get_env line allows" "allow" "$FIXTURE_REMOVED_ONLY" "$TMP_DIR"
(
    cd "$TMP_DIR"
    git checkout -- runtime.exs
    git reset --hard HEAD~1 -q
)

# Test 9: pattern appears only inside a non-.exs file (e.g. a test-authoring
# .sh/.ts fixture whose string literal constructs `System.get_env("X")` text)
# — must NOT block. Regression guard for the file-extension scoping fix.
(
    cd "$TMP_DIR"
    printf 'echo "System.get_env(\\"SCRIPT_ONLY_VAR\\")"\n' >script.sh
    git add script.sh
    git commit -q -m "add unrelated script"
    printf 'echo "System.get_env(\\"SCRIPT_ONLY_VAR\\")"\necho done\n' >script.sh
)
FIXTURE_NON_EXS=$(payload "developer-phoenix-backend" "false")
run_test "pattern in non-.exs file is not scanned (scoping fix)" "allow" "$FIXTURE_NON_EXS" "$TMP_DIR"
(
    cd "$TMP_DIR"
    git checkout -- script.sh
    git reset --hard HEAD~1 -q
)

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
