#!/usr/bin/env bash
# codegen-log_test.sh — unit tests for codegen-log (init / section / append).
#
# Cases:
# (a) --role override yields correct header + rank, ignoring ambient AGENT_TYPE/CLAUDE_ROLE
# (b) empty-body `section --role <role>` opens a placeholder header
# (c) `append --role <role>` preserves prior body and adds the new body in order
# (d) `append` on a missing section exits 2
# (e) unsupported `--role foo` exits 2

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODEGEN_ROOT="$HOOKS_DIR"
CODEGEN_LOG="$CODEGEN_ROOT/codegen-log"

pass=0
fail=0

check() {
    local desc="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %q, got %q\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

assert_contains() {
    local desc="$1"
    local haystack="$2"
    local needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected to find %q\n  got: %s\n' "$desc" "$needle" "${haystack:0:400}"
        fail=$((fail + 1))
    fi
}

new_workspace() {
    local tmp
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/codegen/logging"
    printf '%s' "$tmp"
}

init_log() {
    local root="$1"
    local slug="$2"
    env -u AGENT_TYPE -u CLAUDE_ROLE \
        OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$root" \
        "$CODEGEN_LOG" init --slug "$slug"
}

# ─────────────────────────────────────────────────────────────────────────────
# (a) --role override yields correct header + rank, ignoring ambient env
WS_A="$(new_workspace)"
LOG_A="$(init_log "$WS_A" test-role-override)"
OUT_A=$(printf 'body a\n' | env -u AGENT_TYPE CLAUDE_ROLE=committer \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_A" \
    "$CODEGEN_LOG" section --role reviewer-phoenix --body @-)
CONTENT_A="$(cat "$LOG_A")"
assert_contains "(a) --role override inserts reviewer-phoenix header, not committer" "$CONTENT_A" "## reviewer-phoenix Section"
REVIEWER_LINE=$(grep -n '^## ' "$LOG_A" | tail -1 | cut -d: -f1)
COMMITTER_PRESENT=0
grep -q '^## committer Section' "$LOG_A" && COMMITTER_PRESENT=1
check "(a) committer header NOT inserted (env ignored)" "0" "$COMMITTER_PRESENT"
[ -n "$REVIEWER_LINE" ]

# ─────────────────────────────────────────────────────────────────────────────
# (b) empty-body `section --role <role>` opens a placeholder header
WS_B="$(new_workspace)"
LOG_B="$(init_log "$WS_B" test-empty-open)"
printf '' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_B" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
CONTENT_B="$(cat "$LOG_B")"
assert_contains "(b) empty-body section opens placeholder header" "$CONTENT_B" "## developer-phoenix-backend Section"

# ─────────────────────────────────────────────────────────────────────────────
# (c) append preserves prior body, adds new body in order
WS_C="$(new_workspace)"
LOG_C="$(init_log "$WS_C" test-append-order)"
printf 'ORIGINAL BODY LINE\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_C" \
    "$CODEGEN_LOG" section --role reviewer-phoenix --body @- >/dev/null
printf '### INTERRUPTED marker line\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_C" \
    "$CODEGEN_LOG" append --role reviewer-phoenix --body @- >/dev/null
CONTENT_C="$(cat "$LOG_C")"
assert_contains "(c) append preserves ORIGINAL BODY LINE" "$CONTENT_C" "ORIGINAL BODY LINE"
assert_contains "(c) append adds INTERRUPTED marker" "$CONTENT_C" "### INTERRUPTED marker line"
ORIG_IDX=$(grep -n "ORIGINAL BODY LINE" "$LOG_C" | cut -d: -f1)
MARK_IDX=$(grep -n "INTERRUPTED marker line" "$LOG_C" | cut -d: -f1)
ORDER_OK=0
[ "$ORIG_IDX" -lt "$MARK_IDX" ] && ORDER_OK=1
check "(c) original body precedes appended marker" "1" "$ORDER_OK"

# ─────────────────────────────────────────────────────────────────────────────
# (d) append on a missing section exits 2
WS_D="$(new_workspace)"
init_log "$WS_D" test-append-missing >/dev/null
set +e
ERR_D=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_D" \
    "$CODEGEN_LOG" append --role committer --body @- 2>&1)
RC_D=$?
set -e
check "(d) append on missing section exits 2" "2" "$RC_D"
assert_contains "(d) error names the missing section" "$ERR_D" "committer Section"

# ─────────────────────────────────────────────────────────────────────────────
# (e) unsupported --role foo exits 2
WS_E="$(new_workspace)"
init_log "$WS_E" test-unsupported-role >/dev/null
set +e
ERR_E=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_E" \
    "$CODEGEN_LOG" section --role foo --body @- 2>&1)
RC_E=$?
set -e
check "(e) unsupported --role foo exits 2" "2" "$RC_E"

# ─────────────────────────────────────────────────────────────────────────────
# (f) regression: a target header appearing twice on disk (e.g. a real section
# plus a literal copy of the same heading text embedded in unrelated prose)
# must collapse to exactly ONE occurrence after a section write — the second
# occurrence (and its stale body) must be dropped, never re-emitted.
WS_F="$(new_workspace)"
LOG_F="$(init_log "$WS_F" test-duplicate-heading-collapse)"
printf 'first body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_F" \
    "$CODEGEN_LOG" section --role committer --body @- >/dev/null
# Simulate a second literal occurrence of the same heading appearing in
# unrelated prose (e.g. a planner quoting a delegation prompt verbatim).
printf '\nQuoted prose:\n\n## committer Section\n\nstale prose body\n' >>"$LOG_F"
DUP_COUNT_BEFORE=$(grep -c '^## committer Section$' "$LOG_F")
check "(f) fixture has two literal heading occurrences before write" "2" "$DUP_COUNT_BEFORE"
printf 'second body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_F" \
    "$CODEGEN_LOG" section --role committer --body @- >/dev/null
DUP_COUNT_AFTER=$(grep -c '^## committer Section$' "$LOG_F")
check "(f) duplicate heading collapses to one occurrence after write" "1" "$DUP_COUNT_AFTER"
assert_contains "(f) surviving occurrence has the new body" "$(cat "$LOG_F")" "second body"
STALE_PRESENT=0
grep -q "stale prose body" "$LOG_F" && STALE_PRESENT=1
check "(f) stale second-occurrence body is dropped, not re-emitted" "0" "$STALE_PRESENT"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
