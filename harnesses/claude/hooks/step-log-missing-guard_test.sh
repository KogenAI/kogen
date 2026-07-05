#!/usr/bin/env bash
# step-log-missing-guard_test.sh — unit tests for step-log-missing-guard.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/step-log-missing-guard.sh"

pass=0
fail=0

assert_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s\n  needle: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    fi
}

assert_not_contains() {
    local desc="$1"
    local needle="$2"
    local haystack="$3"
    if printf '%s' "$haystack" | grep -q "$needle"; then
        printf 'FAIL: %s\n  unexpected: %s\n  haystack: %s\n' "$desc" "$needle" "$haystack"
        fail=$((fail + 1))
    else
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    fi
}

make_project() {
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/codegen/logging"
    printf '%s' "$dir"
}

# make_transcript <transcript_path> <log_path> — write synthetic JSONL
# recording a Write to <log_path>.
make_transcript() {
    local transcript_path="$1"
    local log_path="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >"$transcript_path"
}

make_input() {
    local cwd="$1"
    local stop_active="${2:-false}"
    local last_msg="${3:-}"
    local transcript_path="${4:-}"
    jq -n \
        --arg cwd "$cwd" \
        --argjson stop_active "$stop_active" \
        --arg last_msg "$last_msg" \
        --arg transcript_path "$transcript_path" \
        '{"hook_event_name":"Stop","cwd":$cwd,"session_id":"testsession","stop_hook_active":$stop_active,"last_assistant_message":$last_msg,"transcript_path":$transcript_path}'
}

# make_transcript_with_agent <transcript_path> <subagent_type>
# Records an Agent tool_use entry for the given subagent_type.
make_transcript_with_agent() {
    local transcript_path="$1"
    local subagent_type="$2"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"%s"}}]}}\n' \
        "$subagent_type" >"$transcript_path"
}

# make_transcript_agent_and_log <transcript_path> <subagent_type> <log_path>
# Records Agent tool_use entry + Write to log_path.
make_transcript_agent_and_log() {
    local transcript_path="$1"
    local subagent_type="$2"
    local log_path="$3"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"%s"}}]}}\n' \
        "$subagent_type" >"$transcript_path"
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
        "$log_path" >>"$transcript_path"
}

# ── Test (a): no transcript path → no block ──────────────────────────────────
Ta=$(make_project)
out=$(make_input "$Ta" false | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "no transcript path → no block" '"decision"' "$out"
rm -rf "$Ta"

# ── Test (b): transcript with no Agent calls → no block ──────────────────────
Tb=$(make_project)
TRANSCRIPT_Tb="$Tb/transcript.jsonl"
# Only a Write entry, no Agent entry
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/tmp/somefile"}}]}}\n' \
    >"$TRANSCRIPT_Tb"
out=$(make_input "$Tb" false "" "$TRANSCRIPT_Tb" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "transcript with no Agent calls → no block" '"decision"' "$out"
rm -rf "$Tb"

# ── Test (c): developer-phoenix-backend Agent call + log Write → no block ────
Tc=$(make_project)
TRANSCRIPT_Tc="$Tc/transcript.jsonl"
LOG_Tc="$Tc/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
touch "$LOG_Tc"
make_transcript_agent_and_log "$TRANSCRIPT_Tc" "developer-phoenix-backend" "$LOG_Tc"
out=$(make_input "$Tc" false "" "$TRANSCRIPT_Tc" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "developer-backend Agent call + log Write → no block" '"decision"' "$out"
rm -rf "$Tc"

# ── Test (d): developer-phoenix-backend Agent call, no log Write → BLOCK ─────
Td=$(make_project)
TRANSCRIPT_Td="$Td/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Td" "developer-phoenix-backend"
out=$(make_input "$Td" false "" "$TRANSCRIPT_Td" | bash "$HOOK" 2>/dev/null || true)
assert_contains "developer-backend Agent call, no log Write → BLOCK" '"decision"' "$out"
assert_contains "BLOCK reason cites codegen/logging/ path" 'codegen/logging/' "$out"
rm -rf "$Td"

# ── Test (e): planner / reviewer-* only (no developer-*) → no block ──────────
Te=$(make_project)
TRANSCRIPT_Te="$Te/transcript.jsonl"
# planner Agent call
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"planner"}}]}}\n' \
    >"$TRANSCRIPT_Te"
# reviewer-phoenix Agent call appended
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"reviewer-phoenix"}}]}}\n' \
    >>"$TRANSCRIPT_Te"
out=$(make_input "$Te" false "" "$TRANSCRIPT_Te" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "planner/reviewer only → no block" '"decision"' "$out"
rm -rf "$Te"

# ── Test (f): STOP_HOOK_ACTIVE=true → no block ───────────────────────────────
Tf=$(make_project)
TRANSCRIPT_Tf="$Tf/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tf" "developer-phoenix-backend"
out=$(make_input "$Tf" true "" "$TRANSCRIPT_Tf" | bash "$HOOK" 2>/dev/null || true)
assert_not_contains "STOP_HOOK_ACTIVE=true → no block" '"decision"' "$out"
rm -rf "$Tf"

# ── Test (g): intent question in last message → no block ─────────────────────
Tg=$(make_project)
TRANSCRIPT_Tg="$Tg/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tg" "developer-phoenix-backend"
out=$(make_input "$Tg" false "Should I proceed with the next step?" "$TRANSCRIPT_Tg" | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true)
assert_not_contains "intent question in last message → no block" '"decision"' "$out"
rm -rf "$Tg"

# ── Test (h): step log created via Bash heredoc → BLOCK (Bash redirect) ──────
Th=$(make_project)
TRANSCRIPT_Th="$Th/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"developer-phoenix-backend"}}]}}\n' \
    >"$TRANSCRIPT_Th"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cat > /tmp/x/codegen/logging/foo_session.md << '"'"'EOF'"'"'\\n# Step 1\\nEOF"}}]}}\n' \
    >>"$TRANSCRIPT_Th"
out=$(make_input "$Th" false "" "$TRANSCRIPT_Th" | bash "$HOOK" 2>/dev/null || true)
assert_contains "step log via Bash heredoc → BLOCK" '"decision"' "$out"
assert_contains "BLOCK reason cites Bash redirect" 'Bash redirect' "$out"
rm -rf "$Th"

# ── Test (i): step log created via echo redirect → BLOCK (Bash redirect) ─────
Ti=$(make_project)
TRANSCRIPT_Ti="$Ti/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"developer-phoenix-backend"}}]}}\n' \
    >"$TRANSCRIPT_Ti"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo \\\"# Session\\\" > codegen/logging/bar_session.md"}}]}}\n' \
    >>"$TRANSCRIPT_Ti"
out=$(make_input "$Ti" false "" "$TRANSCRIPT_Ti" | bash "$HOOK" 2>/dev/null || true)
assert_contains "step log via echo redirect → BLOCK" '"decision"' "$out"
assert_contains "BLOCK reason cites Bash redirect" 'Bash redirect' "$out"
rm -rf "$Ti"

# ── Test (j): ls/grep on codegen/logging/ path → no Bash-redirect block ──────
Tj=$(make_project)
TRANSCRIPT_Tj="$Tj/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"developer-phoenix-backend"}}]}}\n' \
    >"$TRANSCRIPT_Tj"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls codegen/logging/"}}]}}\n' \
    >>"$TRANSCRIPT_Tj"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -E PATTERN codegen/logging/foo.md"}}]}}\n' \
    >>"$TRANSCRIPT_Tj"
out=$(make_input "$Tj" false "" "$TRANSCRIPT_Tj" | bash "$HOOK" 2>/dev/null || true)
assert_contains "ls/grep on logging path → still BLOCK (no Write)" '"decision"' "$out"
assert_not_contains "ls/grep block reason must NOT cite Bash redirect" 'Bash redirect' "$out"
rm -rf "$Tj"

# ── Test (k): CODEGEN_BUILD_NON_INTERACTIVE suppresses intent escape → BLOCK ──
Tk=$(make_project)
TRANSCRIPT_Tk="$Tk/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tk" "developer-phoenix-backend"
out=$(make_input "$Tk" false "Should I continue?" "$TRANSCRIPT_Tk" | CODEGEN_BUILD_NON_INTERACTIVE=1 bash "$HOOK" 2>/dev/null || true)
assert_contains "headless CODEGEN_BUILD_NON_INTERACTIVE: intent escape suppressed → BLOCK" '"decision"' "$out"
rm -rf "$Tk"

# ── Test (l): interactive intent question still allows (regression guard) ─────
Tl=$(make_project)
TRANSCRIPT_Tl="$Tl/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tl" "developer-phoenix-backend"
out=$(make_input "$Tl" false "Should I continue?" "$TRANSCRIPT_Tl" | env -u CODEGEN_BUILD_NON_INTERACTIVE bash "$HOOK" 2>/dev/null || true)
assert_not_contains "interactive intent question still allows (no CODEGEN_BUILD_NON_INTERACTIVE)" '"decision"' "$out"
rm -rf "$Tl"

# ── Test (m): skip when CLAUDE_ROLE=shape (investigative mode) ────────────────
Tm=$(make_project)
TRANSCRIPT_Tm="$Tm/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tm" "developer-phoenix-backend"
out=$(make_input "$Tm" false "" "$TRANSCRIPT_Tm" | CLAUDE_ROLE=shape bash "$HOOK" 2>/dev/null || true)
assert_not_contains "CLAUDE_ROLE=shape — investigative skip (would block in build mode)" '"decision"' "$out"
rm -rf "$Tm"

# ── Test (n): build mode (role unset) still blocks — behavior unchanged ────────
Tn=$(make_project)
TRANSCRIPT_Tn="$Tn/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tn" "developer-phoenix-backend"
out=$(make_input "$Tn" false "" "$TRANSCRIPT_Tn" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_contains "role unset (build mode) — gate unchanged (still blocks)" '"decision"' "$out"
rm -rf "$Tn"

# ── Test (n2): CLAUDE_ROLE=build still blocks (explicit build role) ───────────
Tn2=$(make_project)
TRANSCRIPT_Tn2="$Tn2/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tn2" "developer-phoenix-backend"
out=$(make_input "$Tn2" false "" "$TRANSCRIPT_Tn2" | CLAUDE_ROLE=build bash "$HOOK" 2>/dev/null || true)
assert_contains "CLAUDE_ROLE=build — explicit build role still enforces (blocks)" '"decision"' "$out"
rm -rf "$Tn2"

# ── Test (o): stale-replay — dev delegated, log created AFTER via codegen-log,
#              later non-dev turns → ALLOW (no stale block) ────────────────────
To=$(make_project)
TRANSCRIPT_To="$To/transcript.jsonl"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"developer-phoenix-backend"}}]}}\n' \
    >"$TRANSCRIPT_To"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"codegen-log section --role planner-phoenix --slug foo --body @-"}}]}}\n' \
    >>"$TRANSCRIPT_To"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"cycle complete; later turn with no new delegation"}]}}\n' \
    >>"$TRANSCRIPT_To"
out=$(make_input "$To" false "" "$TRANSCRIPT_To" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_not_contains "stale-replay: dev logged via codegen-log, later turn no new dev → ALLOW" '"decision"' "$out"
rm -rf "$To"

# ── Test (p): genuine block — a prior log Write, then a LATER dev delegation
#              with no log after it → BLOCK ───────────────────────────────────
Tp=$(make_project)
TRANSCRIPT_Tp="$Tp/transcript.jsonl"
LOG_Tp="$Tp/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_session.md"
touch "$LOG_Tp"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' \
    "$LOG_Tp" >"$TRANSCRIPT_Tp"
printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"subagent_type":"developer-phoenix-backend"}}]}}\n' \
    >>"$TRANSCRIPT_Tp"
out=$(make_input "$Tp" false "" "$TRANSCRIPT_Tp" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_contains "genuine block: log precedes a later un-logged dev delegation → BLOCK" '"decision"' "$out"
assert_contains "genuine block cites codegen/logging/ path" 'codegen/logging/' "$out"
assert_not_contains "diagnostic message: no blind 'Do not investigate' phrasing" 'Do not investigate' "$out"
assert_contains "diagnostic message: names stale-trigger guidance" 'stale' "$out"
rm -rf "$Tp"

# ── Test (q): .active sentinel belt-and-suspenders — dev delegated, transcript
#              has NO log-creation evidence at all, but codegen/logging/.active
#              exists, points at a real log, and is at least as fresh as the
#              transcript → ALLOW (sentinel counts as satisfying evidence) ─────
Tq=$(make_project)
TRANSCRIPT_Tq="$Tq/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tq" "developer-phoenix-backend"
LOG_Tq="$Tq/codegen/logging/$(date -u +%Y%m%d_%H%M%S)_sentinel-test_session.md"
touch "$LOG_Tq"
printf '%s' "$LOG_Tq" >"$Tq/codegen/logging/.active"
# Ensure the sentinel is at least as fresh as the transcript (touch after).
touch "$Tq/codegen/logging/.active"
out=$(make_input "$Tq" false "" "$TRANSCRIPT_Tq" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_not_contains "sentinel belt-and-suspenders: fresh .active → ALLOW (no block)" '"decision"' "$out"
rm -rf "$Tq"

# ── Test (r): stale .active sentinel (older than transcript, or pointing at a
#              deleted log) does NOT satisfy — transcript-position block stands ──
Tr=$(make_project)
TRANSCRIPT_Tr="$Tr/transcript.jsonl"
make_transcript_with_agent "$TRANSCRIPT_Tr" "developer-phoenix-backend"
STALE_LOG_Tr="$Tr/codegen/logging/20200101_000000_deleted-log_session.md"
printf '%s' "$STALE_LOG_Tr" >"$Tr/codegen/logging/.active"
# Deliberately do NOT create $STALE_LOG_Tr — sentinel points at a nonexistent file.
out=$(make_input "$Tr" false "" "$TRANSCRIPT_Tr" | env -u CLAUDE_ROLE -u PI_ROLE bash "$HOOK" 2>/dev/null || true)
assert_contains "stale/dangling sentinel does not satisfy: BLOCK stands" '"decision"' "$out"
rm -rf "$Tr"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
