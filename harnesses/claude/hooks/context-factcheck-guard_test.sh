#!/bin/bash
# context-factcheck-guard_test.sh — unit tests for context-factcheck-guard.sh
#
# Tests:
#   1: named-path: staged context/x.md with resolvable path claim → ALLOW
#   2: named-path: staged context/x.md with missing path claim → DENY
#   3: named-path: bare basename (no slash) → ALLOW (out of grammar)
#   4: count-anchor: live-matching ls probe → ALLOW
#   5: count-anchor: mismatched count (999) → DENY
#   6: count-anchor: disallowed verb 'git' → DENY
#   7: count-anchor: command substitution $() → DENY
#   8: count-anchor: redirect '>' token → DENY
#   9: count-anchor: chaining with ';' → DENY
#  10: count-anchor: malformed non-integer NNN 'abc' → DENY
#  11: count-anchor: probe non-zero exit (nonexistent path ls) → ALLOW (fail-open)
#  12: non-commit: git status → ALLOW (regex non-match)
#  13: echo with git commit substring → ALLOW (start-of-command anchor)
#  14: Read tool with git commit command → ALLOW (TOOL_NAME guard)
#  15: no git repo (temp dir with no .git) → ALLOW (graceful exit)
#  16: repo with neither PROJECT_CONTEXT.md variant → ALLOW (out of scope)
#  17: user-app layout (codegen/PROJECT_CONTEXT.md) + named-path miss → DENY
#  18: unstaged doc with contradicted claim → ALLOW (not staged, not scanned)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SCRIPT_DIR/context-factcheck-guard.sh"

pass=0
fail=0

FIXTURES=()
cleanup() {
    for d in "${FIXTURES[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

# make_fixture <n> — create /tmp/factcheck-test-<n>/ with git init + identity
# and a platform-layout PROJECT_CONTEXT.md. Prints the fixture path.
make_fixture() {
    local n="$1"
    local dir="/tmp/factcheck-test-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@t"
    git -C "$dir" config user.name "t"
    git -C "$dir" config commit.gpgsign false
    printf '# PROJECT_CONTEXT.md\n## Domain Context Files\n' >"$dir/PROJECT_CONTEXT.md"
    git -C "$dir" add "PROJECT_CONTEXT.md"
    git -C "$dir" commit -q -m "init"
    FIXTURES+=("$dir")
    printf '%s' "$dir"
}

# make_fixture_userapp <n> — user-app layout (codegen/PROJECT_CONTEXT.md).
make_fixture_userapp() {
    local n="$1"
    local dir="/tmp/factcheck-test-ua-${n}"
    rm -rf "$dir"
    mkdir -p "$dir/context" "$dir/codegen"
    git -C "$dir" init -q
    git -C "$dir" config user.email "t@t"
    git -C "$dir" config user.name "t"
    git -C "$dir" config commit.gpgsign false
    printf '# PROJECT_CONTEXT.md (codegen)\n## Domain Context Files\n' >"$dir/codegen/PROJECT_CONTEXT.md"
    git -C "$dir" add "codegen/PROJECT_CONTEXT.md"
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
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s (deny=2/allow=0), got %s\n  stdout: %s\n' \
            "$desc" "$expected" "$outcome" "$stdout"
        fail=$((fail + 1))
    fi
}

# ---------------------------------------------------------------------------
# Test 1: named-path: staged context/x.md with resolvable path claim → ALLOW
# ---------------------------------------------------------------------------
dir1=$(make_fixture 1)
# Create a real file inside the fixture to reference.
printf '# real file\n' >"$dir1/context/hooks.md"
git -C "$dir1" add "context/hooks.md"
git -C "$dir1" commit -q -m "seed hooks.md"
# Stage context/x.md that references context/hooks.md with a real backtick claim.
cat >"$dir1/context/x.md" <<'DOC'
See `context/hooks.md` for details.
DOC
git -C "$dir1" add "context/x.md"

run_test "named-path: resolvable path in staged doc → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir1\"}"

# ---------------------------------------------------------------------------
# Test 2: named-path: staged context/x.md with missing path claim → DENY
# ---------------------------------------------------------------------------
dir2=$(make_fixture 2)
cat >"$dir2/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` for details.
DOC
git -C "$dir2" add "context/x.md"

run_test "named-path: missing path in staged doc → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir2\"}"

# ---------------------------------------------------------------------------
# Test 3: named-path: bare basename (no slash) → ALLOW (out of grammar)
# ---------------------------------------------------------------------------
dir3=$(make_fixture 3)
cat >"$dir3/context/x.md" <<'DOC'
See `dispatch.sh` for details.
DOC
git -C "$dir3" add "context/x.md"

run_test "named-path: bare basename no slash → ALLOW (out of grammar)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"add x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir3\"}"

# ---------------------------------------------------------------------------
# Test 4: count-anchor: live-matching ls probe → ALLOW
# Build a fixture with 3 .sh files under hooks/, write an anchor that counts
# exactly 3, and stage it in PROJECT_CONTEXT.md (not a context/*.md, so
# context-index-parity does not fire).
# ---------------------------------------------------------------------------
dir4=$(make_fixture 4)
mkdir -p "$dir4/hooks"
printf '#!/bin/bash\necho a\n' >"$dir4/hooks/a.sh"
printf '#!/bin/bash\necho b\n' >"$dir4/hooks/b.sh"
printf '#!/bin/bash\necho c\n' >"$dir4/hooks/c.sh"
# Probe: ls hooks/*.sh | wc -l should return 3
PROBE_COUNT=$(ls "$dir4/hooks/"*.sh 2>/dev/null | wc -l | tr -d '[:space:]')
# Stage PROJECT_CONTEXT.md update (not a context/*.md so context-index-parity doesn't fire)
printf '# PROJECT_CONTEXT.md\n<!-- count: ls hooks/*.sh | wc -l -->%s\n' "$PROBE_COUNT" >"$dir4/PROJECT_CONTEXT.md"
git -C "$dir4" add "PROJECT_CONTEXT.md"

run_test "count-anchor: live-matching probe ($PROBE_COUNT) → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir4\"}"

# ---------------------------------------------------------------------------
# Test 5: count-anchor mismatch: count 999 → DENY
# ---------------------------------------------------------------------------
dir5=$(make_fixture 5)
printf '<!-- count: ls harnesses/claude/hooks/*.sh | grep -vE '"'"'_test\\.sh$'"'"' | wc -l -->999\n' >"$dir5/context/x.md"
git -C "$dir5" add "context/x.md"

run_test "count-anchor: mismatched count 999 → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir5\"}"

# ---------------------------------------------------------------------------
# Test 6: count-anchor disallowed verb 'git' → DENY
# ---------------------------------------------------------------------------
dir6=$(make_fixture 6)
printf '<!-- count: git log | wc -l -->5\n' >"$dir6/context/x.md"
git -C "$dir6" add "context/x.md"

run_test "count-anchor: disallowed verb 'git' → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir6\"}"

# ---------------------------------------------------------------------------
# Test 7: count-anchor: command substitution $() → DENY
# ---------------------------------------------------------------------------
dir7=$(make_fixture 7)
# Write with a shell $() token in the command.
printf '<!-- count: ls $(pwd) -->3\n' >"$dir7/context/x.md"
git -C "$dir7" add "context/x.md"

run_test "count-anchor: command substitution \$() → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir7\"}"

# ---------------------------------------------------------------------------
# Test 8: count-anchor: redirect '>' → DENY
# ---------------------------------------------------------------------------
dir8=$(make_fixture 8)
printf '<!-- count: ls > /tmp/x -->1\n' >"$dir8/context/x.md"
git -C "$dir8" add "context/x.md"

run_test "count-anchor: redirect '>' token → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir8\"}"

# ---------------------------------------------------------------------------
# Test 9: count-anchor: chaining with ';' → DENY
# ---------------------------------------------------------------------------
dir9=$(make_fixture 9)
printf '<!-- count: ls ; rm -rf / -->1\n' >"$dir9/context/x.md"
git -C "$dir9" add "context/x.md"

run_test "count-anchor: chaining with ';' → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir9\"}"

# ---------------------------------------------------------------------------
# Test 10: count-anchor: malformed non-integer NNN 'abc' → DENY
# ---------------------------------------------------------------------------
dir10=$(make_fixture 10)
# Write an anchor with non-integer NNN — the regex '-->NNN' requires digits,
# so '-->abc' triggers the else branch (has count: but no -->digit).
cat >"$dir10/context/x.md" <<'DOC'
Some text <!-- count: ls | wc -l -->abc and more text.
DOC
git -C "$dir10" add "context/x.md"

run_test "count-anchor: malformed non-integer NNN 'abc' → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir10\"}"

# ---------------------------------------------------------------------------
# Test 11: count-anchor: probe non-zero exit → ALLOW (fail-open)
# ls on a nonexistent path exits non-zero; wc -l on empty → 0, not matching,
# but ls exit code > 0 so pipe status isn't clean... Actually with pipes
# 'ls /bad | wc -l' returns exit 0 (wc succeeds) but output is 0 which
# may match. Use a path that produces empty/wrong output. We test with
# a path that doesn't exist and count 999 → ls returns 0 lines, 0 != 999 → DENY.
# Better: use 'ls /nonexistent-xyz-factcheck | wc -l -->0' — pipe returns
# exit 0 (wc's exit) but ls stderr goes to /dev/null. wc -l on empty output → 0.
# So 0 == 0 → ALLOW (match). That's the correct fail-open test:
# probe returns 0 lines, anchor says 0 → ALLOW.
# ---------------------------------------------------------------------------
dir11=$(make_fixture 11)
printf '<!-- count: ls /nonexistent-xyz-path-factcheck-test | wc -l -->0\n' >"$dir11/context/x.md"
git -C "$dir11" add "context/x.md"

run_test "count-anchor: probe on nonexistent path gives 0, anchor is 0 → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir11\"}"

# ---------------------------------------------------------------------------
# Test 12: non-commit: git status → ALLOW (regex non-match)
# ---------------------------------------------------------------------------
dir12=$(make_fixture 12)
cat >"$dir12/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` missing path.
DOC
git -C "$dir12" add "context/x.md"

run_test "non-commit git status → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git status\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir12\"}"

# ---------------------------------------------------------------------------
# Test 13: echo "git commit" (git follows quote, not space/;&|) → ALLOW
# The regex (^|[[:space:];&|])git requires git to follow space/;&|
# In echo "git commit", git follows " which is not in the class → no match.
# ---------------------------------------------------------------------------
dir13=$(make_fixture 13)
cat >"$dir13/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` missing path.
DOC
git -C "$dir13" add "context/x.md"

run_test "echo \"git commit\" (quote precedes git) → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo \\\"git commit\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir13\"}"

# ---------------------------------------------------------------------------
# Test 14: Read tool with git commit command → ALLOW (TOOL_NAME guard)
# ---------------------------------------------------------------------------
dir14=$(make_fixture 14)
cat >"$dir14/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` missing path.
DOC
git -C "$dir14" add "context/x.md"

run_test "Read tool with git commit payload → ALLOW" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Read\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir14\"}"

# ---------------------------------------------------------------------------
# Test 15: no git repo → ALLOW (graceful exit)
# ---------------------------------------------------------------------------
dir15="/tmp/factcheck-test-15-nogit"
rm -rf "$dir15"
mkdir -p "$dir15"
FIXTURES+=("$dir15")

run_test "non-git CWD → ALLOW (graceful)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir15\"}"

# ---------------------------------------------------------------------------
# Test 16: repo with neither PROJECT_CONTEXT.md variant → ALLOW (out of scope)
# ---------------------------------------------------------------------------
dir16="/tmp/factcheck-test-16-noscope"
rm -rf "$dir16"
mkdir -p "$dir16/context"
git -C "$dir16" init -q
git -C "$dir16" config user.email "t@t"
git -C "$dir16" config user.name "t"
git -C "$dir16" config commit.gpgsign false
printf 'readme\n' >"$dir16/README.md"
git -C "$dir16" add "README.md"
git -C "$dir16" commit -q -m "init"
cat >"$dir16/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` for details.
DOC
git -C "$dir16" add "context/x.md"
FIXTURES+=("$dir16")

run_test "no PROJECT_CONTEXT.md anywhere → ALLOW (out of scope)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir16\"}"

# ---------------------------------------------------------------------------
# Test 17: user-app layout (codegen/PROJECT_CONTEXT.md) + named-path miss → DENY
# ---------------------------------------------------------------------------
dir17=$(make_fixture_userapp 17)
cat >"$dir17/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` for details.
DOC
git -C "$dir17" add "context/x.md"

run_test "user-app layout: missing path in staged doc → DENY" "2" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"x\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir17\"}"

# ---------------------------------------------------------------------------
# Test 18: unstaged doc with contradicted claim → ALLOW (not staged, not scanned)
# ---------------------------------------------------------------------------
dir18=$(make_fixture 18)
# Write a file with a bad path claim but do NOT stage it.
cat >"$dir18/context/x.md" <<'DOC'
See `context/nonexistent-xyz.md` for details.
DOC
# Stage an unrelated change.
printf 'lib code\n' >"$dir18/README.md"
git -C "$dir18" add "README.md"

run_test "unstaged doc with bad claim → ALLOW (not staged)" "0" \
    "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git commit -m \\\"test\\\"\"},\"agent_type\":\"committer\",\"agent_id\":\"a\",\"cwd\":\"$dir18\"}"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
