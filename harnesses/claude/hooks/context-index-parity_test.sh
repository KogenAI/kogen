#!/bin/bash
# context-index-parity_test.sh — unit tests for context-index-parity.sh
#
# Tests:
#   1: git commit -m "x", staged adds context/foo.md, no PROJECT_CONTEXT.md → DENY
#   2: git commit -m "x", staged deletes context/foo.md, no PROJECT_CONTEXT.md → DENY
#   3: Adds context/foo.md AND modifies PROJECT_CONTEXT.md → ALLOW
#   4: Modifies context/foo.md only (no A/D) → ALLOW
#   5: Touches lib/foo.ex only → ALLOW
#   6: git status (non-commit) → ALLOW (regex non-match)
#   7: echo "git commit" → ALLOW (anchor)
#   8: Read tool with git commit payload → ALLOW (TOOL_NAME guard)
#   9: git commit -m "x" in fixture without .git → ALLOW (graceful)
#  10: git commit --amend with orphan add → DENY
#  11: user-app layout (codegen/PROJECT_CONTEXT.md), staged orphan context/foo.md → DENY (subagent committer)
#  12: user-app layout, staged orphan context/foo.md AND codegen/PROJECT_CONTEXT.md → ALLOW
#  13: repo with neither PROJECT_CONTEXT.md nor codegen/PROJECT_CONTEXT.md → ALLOW (not in scope)
#  14: user-app layout deny message names codegen/PROJECT_CONTEXT.md (not root PROJECT_CONTEXT.md)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/context-index-parity.sh"

pass=0
fail=0

# Cleanup fixtures at exit.
FIXTURES=()
cleanup() {
    for d in "${FIXTURES[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# make_fixture <n> — create /tmp/context-parity-test-<n>/ with git init + identity.
# Prints the fixture path.
make_fixture() {
    local n="$1"
    local dir="/tmp/context-parity-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context" "$dir/lib"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@t"
    git -C "$dir" config user.name "t"
    # Seed a base PROJECT_CONTEXT.md so the repo has at least one commit's worth of history.
    printf '# PROJECT_CONTEXT.md\n## Domain Context Files\n' >"$dir/PROJECT_CONTEXT.md"
    git -C "$dir" add PROJECT_CONTEXT.md
    git -C "$dir" commit -q -m "init"
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

run_test() {
    local desc="$1"
    local expected="$2"
    local input="$3"

    local stdout
    stdout=$(printf '%s' "$input" | bash "$GUARD" 2>/dev/null || true)

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

# ---------------------------------------------------------------------------
# Test 1: git commit -m "x", staged adds context/foo.md, no PROJECT_CONTEXT.md
# ---------------------------------------------------------------------------
dir1=$(make_fixture 1)
printf 'context\n' >"$dir1/context/foo.md"
git -C "$dir1" add "context/foo.md"

run_test "staged add context/foo.md, no PROJECT_CONTEXT.md change → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir1\"}"

# ---------------------------------------------------------------------------
# Test 2: staged deletes context/foo.md, no PROJECT_CONTEXT.md
# ---------------------------------------------------------------------------
dir2=$(make_fixture 2)
printf 'context\n' >"$dir2/context/bar.md"
git -C "$dir2" add "context/bar.md"
git -C "$dir2" commit -q -m "add bar"
git -C "$dir2" rm -q "context/bar.md"
# PROJECT_CONTEXT.md is NOT staged for modification.

run_test "staged delete context/bar.md, no PROJECT_CONTEXT.md change → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"remove\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir2\"}"

# ---------------------------------------------------------------------------
# Test 3: adds context/foo.md AND modifies PROJECT_CONTEXT.md → ALLOW
# ---------------------------------------------------------------------------
dir3=$(make_fixture 3)
printf 'context\n' >"$dir3/context/new.md"
git -C "$dir3" add "context/new.md"
printf '# PROJECT_CONTEXT.md\n## Domain Context Files\n- context/new.md\n' >"$dir3/PROJECT_CONTEXT.md"
git -C "$dir3" add "PROJECT_CONTEXT.md"

run_test "staged add context/new.md + PROJECT_CONTEXT.md → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add context\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir3\"}"

# ---------------------------------------------------------------------------
# Test 4: modifies context/foo.md only (no A/D) → ALLOW
# ---------------------------------------------------------------------------
dir4=$(make_fixture 4)
printf 'v1\n' >"$dir4/context/existing.md"
git -C "$dir4" add "context/existing.md"
git -C "$dir4" commit -q -m "add existing"
printf 'v2\n' >"$dir4/context/existing.md"
git -C "$dir4" add "context/existing.md"

run_test "modify-only context/existing.md (M) → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"update\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir4\"}"

# ---------------------------------------------------------------------------
# Test 5: touches lib/foo.ex only → ALLOW
# ---------------------------------------------------------------------------
dir5=$(make_fixture 5)
printf 'defmodule Foo do\nend\n' >"$dir5/lib/foo.ex"
git -C "$dir5" add "lib/foo.ex"

run_test "lib/foo.ex only → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add foo\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir5\"}"

# ---------------------------------------------------------------------------
# Test 6: git status (non-commit) → ALLOW (regex non-match)
# ---------------------------------------------------------------------------
dir6=$(make_fixture 6)
printf 'x\n' >"$dir6/context/a.md"
git -C "$dir6" add "context/a.md"

run_test "git status (non-commit) → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir6\"}"

# ---------------------------------------------------------------------------
# Test 7: echo "git commit" → ALLOW (anchor prevents substring match)
# ---------------------------------------------------------------------------
dir7=$(make_fixture 7)
printf 'x\n' >"$dir7/context/b.md"
git -C "$dir7" add "context/b.md"

run_test "echo \"git commit\" substring → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\"git commit\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir7\"}"

# ---------------------------------------------------------------------------
# Test 8: Read tool with git commit payload → ALLOW (TOOL_NAME guard)
# ---------------------------------------------------------------------------
dir8=$(make_fixture 8)
printf 'x\n' >"$dir8/context/c.md"
git -C "$dir8" add "context/c.md"

run_test "Read tool with git commit payload → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir8\"}"

# ---------------------------------------------------------------------------
# Test 9: git commit -m "x" in fixture without .git → ALLOW (graceful)
# ---------------------------------------------------------------------------
dir9="/tmp/context-parity-test-9-nogit"
rm -rf "$dir9"
mkdir -p "$dir9"
FIXTURES+=("$dir9")

run_test "non-git CWD → ALLOW (graceful)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir9\"}"

# ---------------------------------------------------------------------------
# Test 10: git commit --amend with orphan add → DENY
# ---------------------------------------------------------------------------
dir10=$(make_fixture 10)
printf 'content\n' >"$dir10/context/amend.md"
git -C "$dir10" add "context/amend.md"

run_test "git commit --amend with orphan add → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit --amend\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir10\"}"

# ---------------------------------------------------------------------------
# make_fixture_userapp <n> — user-app layout: codegen/PROJECT_CONTEXT.md present,
# no top-level PROJECT_CONTEXT.md. Prints fixture path.
# ---------------------------------------------------------------------------
make_fixture_userapp() {
    local n="$1"
    local dir="/tmp/context-parity-test-ua-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context" "$dir/lib" "$dir/codegen"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@t"
    git -C "$dir" config user.name "t"
    printf '# PROJECT_CONTEXT.md (codegen)\n## Domain Context Files\n' >"$dir/codegen/PROJECT_CONTEXT.md"
    git -C "$dir" add "codegen/PROJECT_CONTEXT.md"
    git -C "$dir" commit -q -m "init"
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

# ---------------------------------------------------------------------------
# Test 11: user-app layout, staged orphan context/foo.md, no index update → DENY
# Committer runs as subagent — AGENT_TYPE set. Hook MUST still fire.
# ---------------------------------------------------------------------------
dir11=$(make_fixture_userapp 11)
printf 'content\n' >"$dir11/context/foo.md"
git -C "$dir11" add "context/foo.md"

run_test "user-app layout: staged add context/foo.md, no codegen/PROJECT_CONTEXT.md change, committer subagent → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add foo\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir11\"}"

# ---------------------------------------------------------------------------
# Test 12: user-app layout, staged orphan context/foo.md AND codegen/PROJECT_CONTEXT.md → ALLOW
# ---------------------------------------------------------------------------
dir12=$(make_fixture_userapp 12)
printf 'content\n' >"$dir12/context/new.md"
git -C "$dir12" add "context/new.md"
printf '# PROJECT_CONTEXT.md (codegen)\n## Domain Context Files\n- context/new.md\n' >"$dir12/codegen/PROJECT_CONTEXT.md"
git -C "$dir12" add "codegen/PROJECT_CONTEXT.md"

run_test "user-app layout: staged add context/new.md + codegen/PROJECT_CONTEXT.md → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add context\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir12\"}"

# ---------------------------------------------------------------------------
# Test 13: repo with neither PROJECT_CONTEXT.md nor codegen/PROJECT_CONTEXT.md → ALLOW (not in scope)
# ---------------------------------------------------------------------------
dir13="/tmp/context-parity-test-noscope"
rm -rf "$dir13"
mkdir -p "$dir13/context"
git -C "$dir13" init -q
git -C "$dir13" config user.email "t@t"
git -C "$dir13" config user.name "t"
printf 'readme\n' >"$dir13/README.md"
git -C "$dir13" add "README.md"
git -C "$dir13" commit -q -m "init"
printf 'content\n' >"$dir13/context/foo.md"
git -C "$dir13" add "context/foo.md"
FIXTURES+=("$dir13")

run_test "no PROJECT_CONTEXT.md anywhere → ALLOW (not in scope)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir13\"}"

# ---------------------------------------------------------------------------
# Test 14: user-app layout deny message names codegen/PROJECT_CONTEXT.md (not root)
# ---------------------------------------------------------------------------
dir14=$(make_fixture_userapp 14)
printf 'content\n' >"$dir14/context/orphan.md"
git -C "$dir14" add "context/orphan.md"

stdout14=$(printf '%s' \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir14\"}" |
    bash "$GUARD" 2>/dev/null || true)

if printf '%s' "$stdout14" | grep -q "codegen/PROJECT_CONTEXT.md"; then
    printf 'PASS: user-app layout deny message names codegen/PROJECT_CONTEXT.md\n'
    pass=$((pass + 1))
else
    printf 'FAIL: user-app layout deny message does not name codegen/PROJECT_CONTEXT.md\n  stdout: %s\n' "$stdout14"
    fail=$((fail + 1))
fi

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
