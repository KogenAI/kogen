#!/usr/bin/env bash
# mode-matrix_test.sh — hermetic composition test for Agent-matcher PreToolUse hooks.
#
# Discovers Agent-matcher hooks dynamically from claude-code-settings.json so any
# new Agent hook auto-participates without updating this file.
#
# First-deny-wins: if any hook outputs "permissionDecision": "deny", composed verdict = deny.
# Tests an expectation table covering (CLAUDE_ROLE, subagent_type, transcript) combinations.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Hook Discovery ─────────────────────────────────────────────────────────────

# discover_agent_hooks — reads claude-code-settings.json, filters PreToolUse hooks
# whose matcher matches "Agent" (exact or union like "Agent|Foo"), strips the
# $HOME/.claude/hooks/ prefix, and resolves each to its in-repo source copy under
# $SCRIPT_DIR. Prints one resolved path per line.
discover_agent_hooks() {
    local settings="$SCRIPT_DIR/../claude-code-settings.json"
    jq -r '[.hooks.PreToolUse[] | select(.matcher | test("(^|\\|)Agent(\\||$)")) | .hooks[].command] | .[]' \
        "$settings" |
        while IFS= read -r cmd; do
            local name
            name="${cmd##*/}" # strip path prefix → basename (e.g. operator-subagent-allowlist.sh)
            printf '%s/%s\n' "$SCRIPT_DIR" "$name"
        done
}

pass=0
fail=0

# ── Helpers ────────────────────────────────────────────────────────────────────

assert_deny() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    fi
}

assert_allow() {
    local desc="$1"
    local stdout="$2"
    if printf '%s' "$stdout" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
        printf 'FAIL: %s — expected allow, got deny\n  stdout: %s\n' "$desc" "$stdout"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

# make_transcript <transcript_path> <log_path>
make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

# mk_agent_input <subagent_type> <transcript_path> [cwd]
mk_agent_input() {
    local stype="$1"
    local transcript_path="$2"
    local cwd="${3:-}"
    jq -n \
        --arg s "$stype" \
        --arg t "$transcript_path" \
        --arg c "$cwd" \
        '{"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"subagent_type":$s,"description":"x","prompt":"y"},"agent_id":"","agent_type":"","transcript_path":$t,"cwd":$c}'
}

# composed_verdict <role> <subagent_type> <transcript_path> [cwd]
# Pipes Agent input through all discovered Agent-matcher hooks in order; first deny wins.
# Optional [cwd] scopes hooks' CWD resolution (e.g. codegen/logging/.active lookup) to a
# fixture directory instead of leaking the real repo's ambient $PWD/.active sentinel.
composed_verdict() {
    local role="$1"
    local stype="$2"
    local transcript_path="$3"
    local cwd="${4:-}"

    local hooks=()
    while IFS= read -r h; do
        hooks+=("$h")
    done < <(discover_agent_hooks)

    local agent_input
    agent_input=$(mk_agent_input "$stype" "$transcript_path" "$cwd")

    for hook in "${hooks[@]}"; do
        local out
        if [ -n "$role" ]; then
            out=$(printf '%s' "$agent_input" | CLAUDE_ROLE="$role" bash "$hook" 2>/dev/null || true)
        else
            out=$(printf '%s' "$agent_input" | bash "$hook" 2>/dev/null || true)
        fi
        if printf '%s' "$out" | grep -q '"permissionDecision"[[:space:]]*:[[:space:]]*"deny"'; then
            printf '%s' "$out"
            return 0
        fi
    done
    # No hook denied — allow (empty stdout = allow)
    printf ''
}

# ── Fixtures ───────────────────────────────────────────────────────────────────

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Empty transcript (no log reference)
EMPTY_TRANSCRIPT="$TMPDIR_BASE/empty_transcript.jsonl"
printf '' >"$EMPTY_TRANSCRIPT"

# Transcript + session log with developer-phoenix-backend section header (row 5)
LOG5_DIR="$TMPDIR_BASE/project_r5"
mkdir -p "$LOG5_DIR/codegen/logging"
LOG5_PATH="$LOG5_DIR/codegen/logging/test-session.md"
printf '## developer-phoenix-backend Section\n' >"$LOG5_PATH"
TRANSCRIPT5="$LOG5_DIR/transcript.jsonl"
make_transcript "$TRANSCRIPT5" "$LOG5_PATH"

# ── Expectation Table ──────────────────────────────────────────────────────────
# Hooks are discovered dynamically from claude-code-settings.json (discover_agent_hooks).
# Currently: operator-subagent-allowlist
#
# | row | CLAUDE_ROLE           | subagent_type             | transcript     | expected |
# |-----|-----------------------|---------------------------|----------------|----------|
# | 1   | shape                 | Explore                   | empty (no log) | allow    |
# | 2   | debug                 | Explore                   | empty (no log) | allow    |
# | 3   | ops                   | Explore                   | empty (no log) | allow    |
# | 4   | (empty)               | Explore                   | empty (no log) | deny     |
# | 5   | (empty)               | developer-phoenix-backend | with-log+header| allow    |

# Row 1: CLAUDE_ROLE=shape, Explore, no log → allow
out1=$(composed_verdict "shape" "Explore" "$EMPTY_TRANSCRIPT")
assert_allow "row1: shape + Explore + no-log → allow" "$out1"

# Row 2: CLAUDE_ROLE=debug, Explore, no log → allow
out2=$(composed_verdict "debug" "Explore" "$EMPTY_TRANSCRIPT")
assert_allow "row2: debug + Explore + no-log → allow" "$out2"

# Row 3: CLAUDE_ROLE=ops, Explore, no log → allow
out3=$(composed_verdict "ops" "Explore" "$EMPTY_TRANSCRIPT")
assert_allow "row3: ops + Explore + no-log → allow" "$out3"

# Row 4: no role, Explore, no log → deny (operator-subagent-allowlist blocks built-in Explore without role)
out4=$(composed_verdict "" "Explore" "$EMPTY_TRANSCRIPT")
assert_deny "row4: no-role + Explore + no-log → deny" "$out4"

# Row 5: no role, developer-phoenix-backend, with-log + section header → allow
out5=$(composed_verdict "" "developer-phoenix-backend" "$TRANSCRIPT5" "$LOG5_DIR")
assert_allow "row5: no-role + developer-phoenix-backend + with-log+header → allow" "$out5"

# ── Results ────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
