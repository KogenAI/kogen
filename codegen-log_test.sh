#!/usr/bin/env bash
# codegen-log_test.sh — unit tests for codegen-log (init / section / append).
#
# Cases:
# (a) --role override yields correct header + rank, ignoring ambient AGENT_TYPE/CLAUDE_ROLE
# (b) empty-body `section --role <role>` opens a placeholder header
# (c) `append --role <role>` preserves prior body and adds the new body in order
# (d) `append` on a missing section exits 2
# (e) unsupported `--role foo` exits 2, error names --role remedy
# (g) `init` is idempotent: re-init on an existing slug prints the same path;
#     a distinct slug forks a new log
# (h) `--slug` resolves to the matching log among multiple logs in one workspace
# (i) `--slug` with zero matches exits 2 with "no session log matches slug"
# (j) `--slug` with multiple matches exits 2 with "ambiguous slug"
# (k) append-missing error names the fix command

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
assert_contains "(e) unsupported-role error names --role remedy" "$ERR_E" "--role"

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
# (g) init is idempotent: re-init on an existing slug prints the same path;
# a distinct slug forks a NEW path.
WS_G="$(new_workspace)"
LOG_G1="$(init_log "$WS_G" test-idempotent)"
LOG_G2="$(init_log "$WS_G" test-idempotent)"
check "(g) idempotent init returns the same path on re-init" "$LOG_G1" "$LOG_G2"
LOG_G3="$(init_log "$WS_G" test-idempotent-other)"
IDEMPOTENT_DISTINCT=1
[ "$LOG_G1" = "$LOG_G3" ] && IDEMPOTENT_DISTINCT=0
check "(g) a distinct slug forks a new log" "1" "$IDEMPOTENT_DISTINCT"

# ─────────────────────────────────────────────────────────────────────────────
# (h) --slug resolves to the matching log among multiple logs in one workspace
WS_H="$(new_workspace)"
LOG_H1="$(init_log "$WS_H" slug-one)"
LOG_H2="$(init_log "$WS_H" slug-two)"
printf 'body for slug one\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_H" \
    "$CODEGEN_LOG" section --role committer --slug slug-one --body @- >/dev/null
CONTENT_H1="$(cat "$LOG_H1")"
CONTENT_H2="$(cat "$LOG_H2")"
assert_contains "(h) --slug section writes into the matching log" "$CONTENT_H1" "body for slug one"
NOT_IN_H2=1
[[ "$CONTENT_H2" == *"body for slug one"* ]] && NOT_IN_H2=0
check "(h) --slug section does NOT write into the non-matching log" "1" "$NOT_IN_H2"

# ─────────────────────────────────────────────────────────────────────────────
# (i) --slug with zero matches exits 2 with "no session log matches slug"
WS_I="$(new_workspace)"
init_log "$WS_I" some-other-slug >/dev/null
set +e
ERR_I=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_I" \
    "$CODEGEN_LOG" section --role committer --slug missing-slug --body @- 2>&1)
RC_I=$?
set -e
check "(i) --slug zero-match exits 2" "2" "$RC_I"
assert_contains "(i) --slug zero-match error message" "$ERR_I" "no session log matches slug"

# ─────────────────────────────────────────────────────────────────────────────
# (j) --slug with multiple matches exits 2 with "ambiguous slug"
WS_J="$(new_workspace)"
touch "$WS_J/codegen/logging/20260101_000001_dup_session.md"
touch "$WS_J/codegen/logging/20260101_000002_dup_session.md"
set +e
ERR_J=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_J" \
    "$CODEGEN_LOG" section --role committer --slug dup --body @- 2>&1)
RC_J=$?
set -e
check "(j) --slug many-match exits 2" "2" "$RC_J"
assert_contains "(j) --slug many-match error message" "$ERR_J" "ambiguous slug"

# ─────────────────────────────────────────────────────────────────────────────
# (k) append-missing error names the fix command
WS_K="$(new_workspace)"
init_log "$WS_K" test-append-missing-fix >/dev/null
set +e
ERR_K=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_K" \
    "$CODEGEN_LOG" append --role committer --body @- 2>&1)
RC_K=$?
set -e
check "(k) append-missing exits 2" "2" "$RC_K"
assert_contains "(k) append-missing error names the fix command" "$ERR_K" "codegen-log section --role"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
