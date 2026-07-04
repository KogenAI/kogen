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
# (l) `section` body containing a stray "## Fake Header" line is indented,
#     never promoted to a real col-0 section
# (m) `section` body containing "### What I Learned This Step" (H3) stays
#     col-0 untouched — regression guard for the H2-only scope limit
# (n) `section` body containing "# Step 1" (H1) stays col-0 untouched
# (o) `section` plain-prose body passes through byte-identical
# (p) `section` self-prefixed header body: outer header stripped, an inner
#     stray "## Bar" in the remaining prose is indented
# (q) `append` body containing a stray "## Baz" line is indented, never
#     promoted to a real col-0 section

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
# (l) section: stray "## Fake Header" in body is indented, never promoted
WS_L="$(new_workspace)"
LOG_L="$(init_log "$WS_L" test-opaque-h2)"
printf 'prose before\n\n## Fake Header\n\nprose after\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_L" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
assert_contains "(l) stray H2 body line is indented" "$(cat "$LOG_L")" "  ## Fake Header"
FAKE_COL0_COUNT=$(grep -c '^## Fake Header$' "$LOG_L" || true)
check "(l) stray H2 body line never appears at col-0" "0" "$FAKE_COL0_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# (m) section: author-typed H3 retro marker stays col-0 untouched
WS_M="$(new_workspace)"
LOG_M="$(init_log "$WS_M" test-opaque-h3-untouched)"
printf '### What I Learned This Step\n\n- learned x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_M" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
H3_COL0_COUNT=$(grep -c '^### What I Learned This Step$' "$LOG_M")
check "(m) H3 retro marker stays col-0 (untouched)" "1" "$H3_COL0_COUNT"
H3_INDENTED_COUNT=$(grep -c '^  ### What I Learned This Step$' "$LOG_M" || true)
check "(m) H3 retro marker is NOT indented" "0" "$H3_INDENTED_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# (n) section: H1 title line stays col-0 untouched
WS_N="$(new_workspace)"
LOG_N="$(init_log "$WS_N" test-opaque-h1-untouched)"
printf '# Step 1\n\nend prose\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_N" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
H1_COL0_COUNT=$(grep -c '^# Step 1$' "$LOG_N")
check "(n) H1 title line stays col-0 (untouched)" "1" "$H1_COL0_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# (o) section: plain-prose body passes through byte-identical
WS_O="$(new_workspace)"
LOG_O="$(init_log "$WS_O" test-opaque-prose-passthrough)"
printf 'just plain prose\nwith multiple lines\nno structural markers\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_O" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
assert_contains "(o) plain prose passes through unchanged" "$(cat "$LOG_O")" $'just plain prose\nwith multiple lines\nno structural markers'

# ─────────────────────────────────────────────────────────────────────────────
# (p) section: self-prefixed header stripped, remaining stray "## Bar" indented
WS_P="$(new_workspace)"
LOG_P="$(init_log "$WS_P" test-opaque-self-header)"
printf '## developer-phoenix-backend Section\n\nprose\n\n## Bar\n\nmore prose\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_P" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
OUTER_HEADER_COUNT=$(grep -c '^## developer-phoenix-backend Section$' "$LOG_P")
check "(p) self-prefixed outer header appears exactly once (stripped, not duplicated)" "1" "$OUTER_HEADER_COUNT"
assert_contains "(p) inner stray H2 is indented" "$(cat "$LOG_P")" "  ## Bar"
BAR_COL0_COUNT=$(grep -c '^## Bar$' "$LOG_P" || true)
check "(p) inner stray H2 never appears at col-0" "0" "$BAR_COL0_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# (q) append: stray "## Baz" in appended body is indented, never promoted
WS_Q="$(new_workspace)"
LOG_Q="$(init_log "$WS_Q" test-opaque-append-h2)"
printf 'original body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_Q" \
    "$CODEGEN_LOG" section --role committer --body @- >/dev/null
printf 'appended prose\n\n## Baz\n\nmore appended prose\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_Q" \
    "$CODEGEN_LOG" append --role committer --body @- >/dev/null
assert_contains "(q) appended stray H2 is indented" "$(cat "$LOG_Q")" "  ## Baz"
BAZ_COL0_COUNT=$(grep -c '^## Baz$' "$LOG_Q" || true)
check "(q) appended stray H2 never appears at col-0" "0" "$BAZ_COL0_COUNT"

# ─────────────────────────────────────────────────────────────────────────────
# (r) append --learned emits the byte-exact retro block, positioned so retro
# extraction finds it (### What I Learned This Step, blank line, then text).
WS_R="$(new_workspace)"
LOG_R="$(init_log "$WS_R" test-learned-marker)"
printf 'body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_R" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_R" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --learned "- nothing notable" >/dev/null
CONTENT_R="$(cat "$LOG_R")"
assert_contains "(r) --learned emits byte-exact header" "$CONTENT_R" "### What I Learned This Step"
assert_contains "(r) --learned emits the supplied text" "$CONTENT_R" "- nothing notable"
LEARNED_LINE=$(grep -n '^### What I Learned This Step$' "$LOG_R" | cut -d: -f1)
[ -n "$LEARNED_LINE" ]
NEXT_LINE=$((LEARNED_LINE + 1))
BLANK_AFTER=$(sed -n "${NEXT_LINE}p" "$LOG_R")
check "(r) --learned header followed by blank line" "" "$BLANK_AFTER"

# ─────────────────────────────────────────────────────────────────────────────
# (s) append --died interrupted/aborted emits the byte-exact death markers.
WS_S="$(new_workspace)"
LOG_S="$(init_log "$WS_S" test-died-marker)"
printf 'body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_S" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_S" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --died interrupted --cause "timeout" >/dev/null
CONTENT_S="$(cat "$LOG_S")"
assert_contains "(s) --died interrupted emits byte-exact marker" "$CONTENT_S" "### INTERRUPTED ⚠️ — developer-phoenix-backend dropped (timeout); re-spawning (attempt N/2)"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_S" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --died aborted >/dev/null
CONTENT_S2="$(cat "$LOG_S")"
assert_contains "(s) --died aborted emits byte-exact marker" "$CONTENT_S2" "### ABORTED 💀 — developer-phoenix-backend dropped twice; stage failed."

# ─────────────────────────────────────────────────────────────────────────────
# (t) append --verdict clear|failed|inconclusive emits the byte-exact emoji
# strings the stop-cycle-guard reader greps for.
WS_T="$(new_workspace)"
LOG_T="$(init_log "$WS_T" test-verdict-marker)"
printf 'body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --verdict clear >/dev/null
assert_contains "(t) --verdict clear emits ALL CLEAR" "$(cat "$LOG_T")" "ALL CLEAR ✅"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --verdict failed >/dev/null
assert_contains "(t) --verdict failed emits FAILED" "$(cat "$LOG_T")" "FAILED ❌"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --verdict inconclusive >/dev/null
assert_contains "(t) --verdict inconclusive emits INCONCLUSIVE" "$(cat "$LOG_T")" "INCONCLUSIVE ⚠️"

# ─────────────────────────────────────────────────────────────────────────────
# (u) --learned/--died/--verdict are mutually exclusive with each other and
# with --body; --learned/--died/--verdict are append-only.
WS_U="$(new_workspace)"
init_log "$WS_U" test-marker-exclusivity >/dev/null
set +e
ERR_U1=$(env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_U" \
    "$CODEGEN_LOG" append --role committer --learned "x" --verdict clear 2>&1)
RC_U1=$?
set -e
check "(u) --learned + --verdict exits 2" "2" "$RC_U1"
assert_contains "(u) mutual-exclusivity error message" "$ERR_U1" "mutually exclusive"

set +e
ERR_U2=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_U" \
    "$CODEGEN_LOG" section --role committer --learned "x" 2>&1)
RC_U2=$?
set -e
check "(u) --learned on section subcommand exits 2" "2" "$RC_U2"
assert_contains "(u) append-only error message" "$ERR_U2" "append"

# ─────────────────────────────────────────────────────────────────────────────
# (v) init writes the .active sentinel with the resolved absolute log path.
WS_V="$(new_workspace)"
LOG_V="$(init_log "$WS_V" test-active-sentinel)"
SENTINEL_V="$WS_V/codegen/logging/.active"
check "(v) init writes .active sentinel file" "0" "$([ -f "$SENTINEL_V" ] && printf 0 || printf 1)"
check "(v) .active sentinel contains the resolved log path" "$LOG_V" "$(cat "$SENTINEL_V")"

# ─────────────────────────────────────────────────────────────────────────────
# (w) positional role resolves for section/append; implicit stdin (no --body).
WS_W="$(new_workspace)"
LOG_W="$(init_log "$WS_W" test-positional-role)"
printf 'positional section body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_W" \
    "$CODEGEN_LOG" section developer-phoenix-backend >/dev/null
assert_contains "(w) positional section resolves role + implicit stdin" "$(cat "$LOG_W")" "positional section body"
printf 'positional append body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_W" \
    "$CODEGEN_LOG" append developer-phoenix-backend >/dev/null
assert_contains "(w) positional append resolves role + implicit stdin" "$(cat "$LOG_W")" "positional append body"

# ─────────────────────────────────────────────────────────────────────────────
# (x) .active sentinel precedence: with no CODEGEN_LOG_PATH/--slug given, the
# sentinel-pointed log is used, NOT the most-recently-touched log on disk.
WS_X="$(new_workspace)"
LOG_X1="$(init_log "$WS_X" test-sentinel-precedence-one)"
LOG_X2="$(init_log "$WS_X" test-sentinel-precedence-two)"
# .active now points at LOG_X2 (the most recent init). Touch LOG_X1 so mtime
# fallback (if wrongly used) would pick LOG_X1 instead.
touch "$LOG_X1"
printf 'via sentinel\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_X" \
    "$CODEGEN_LOG" section developer-phoenix-backend >/dev/null
VIA_SENTINEL_IN_X2=0
grep -q "via sentinel" "$LOG_X2" && VIA_SENTINEL_IN_X2=1
check "(x) .active sentinel is honored over a more-recently-touched log" "1" "$VIA_SENTINEL_IN_X2"
VIA_SENTINEL_IN_X1=0
grep -q "via sentinel" "$LOG_X1" && VIA_SENTINEL_IN_X1=1
check "(x) .active sentinel write did not divert to the touched log" "0" "$VIA_SENTINEL_IN_X1"

# ─────────────────────────────────────────────────────────────────────────────
# (y) relocate renames the log file and rewrites .active to the new path.
WS_Y="$(new_workspace)"
LOG_Y="$(init_log "$WS_Y" test-relocate-old)"
RELOCATE_OUT_Y=$(env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_Y" \
    "$CODEGEN_LOG" relocate --new-slug test-relocate-new)
NEW_LOG_Y=$(printf '%s' "$RELOCATE_OUT_Y" | tail -n 1)
check "(y) relocate returns a path ending in the new slug" "0" "$([[ "$NEW_LOG_Y" == *_test-relocate-new_session.md ]] && printf 0 || printf 1)"
check "(y) old log path no longer exists after relocate" "0" "$([ ! -f "$LOG_Y" ] && printf 0 || printf 1)"
check "(y) new log path exists after relocate" "0" "$([ -f "$NEW_LOG_Y" ] && printf 0 || printf 1)"
check "(y) .active sentinel rewritten to the new path" "$NEW_LOG_Y" "$(cat "$WS_Y/codegen/logging/.active")"

# ─────────────────────────────────────────────────────────────────────────────
# (z) bare positional-less section/append with no --role and no ambient env
# still exits 2 with a clear error naming both remedies (positional + --role);
# the old dead bare-`section` env-role fallback (AGENT_TYPE/CLAUDE_ROLE) is
# removed — ambient env vars are NEVER consulted.
WS_Z="$(new_workspace)"
init_log "$WS_Z" test-bare-section-removed >/dev/null
set +e
ERR_Z=$(printf 'x\n' | env AGENT_TYPE=developer-phoenix-backend CLAUDE_ROLE=developer-phoenix-backend \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_Z" \
    "$CODEGEN_LOG" section --body @- 2>&1)
RC_Z=$?
set -e
check "(z) bare section with no role exits 2 even with AGENT_TYPE/CLAUDE_ROLE set" "2" "$RC_Z"
assert_contains "(z) error names the positional remedy" "$ERR_Z" "positional"
assert_contains "(z) error names the --role remedy" "$ERR_Z" "--role"

# ─────────────────────────────────────────────────────────────────────────────
# (aa) `verdict` writes the byte-exact "## dev-gate Section" block (Gate:/Ran:/
# **Rules loaded**:/**Commands executed**: table/**Result**:), and repeated
# calls APPEND a fresh block each time rather than replacing the prior one
# (dev-gate re-runs across retries must all remain visible).
WS_AA="$(new_workspace)"
LOG_AA="$(init_log "$WS_AA" test-verdict-subcommand)"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_AA" \
    "$CODEGEN_LOG" verdict --gate "make test" --mode short --result "ALL CLEAR ✅" >/dev/null
CONTENT_AA1="$(cat "$LOG_AA")"
assert_contains "(aa) verdict emits dev-gate Section header" "$CONTENT_AA1" "## dev-gate Section"
assert_contains "(aa) verdict emits Gate: line" "$CONTENT_AA1" "Gate: make test"
assert_contains "(aa) verdict emits Ran: line" "$CONTENT_AA1" "Ran: make test"
assert_contains "(aa) verdict emits Rules loaded line" "$CONTENT_AA1" "**Rules loaded**: deterministic hook (dev-gate.sh) — no rules loaded"
assert_contains "(aa) verdict emits Commands executed table" "$CONTENT_AA1" "**Commands executed**:"
assert_contains "(aa) verdict emits table header row" "$CONTENT_AA1" "| Time (HH:MM:SS UTC) | Command | Exit | Notes |"
assert_contains "(aa) verdict emits Result line" "$CONTENT_AA1" "**Result**: ALL CLEAR ✅"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_AA" \
    "$CODEGEN_LOG" verdict --gate "make test" --mode short --result "FAILED ❌ exit=1" --detail "Log: /tmp/foo.log" >/dev/null
CONTENT_AA2="$(cat "$LOG_AA")"
DEV_GATE_COUNT_AA=$(grep -c '^## dev-gate Section$' "$LOG_AA")
check "(aa) second verdict call appends a NEW dev-gate Section (does not replace)" "2" "$DEV_GATE_COUNT_AA"
assert_contains "(aa) first verdict block still present after second call" "$CONTENT_AA2" "**Result**: ALL CLEAR ✅"
assert_contains "(aa) second verdict block present" "$CONTENT_AA2" "**Result**: FAILED ❌ exit=1"
assert_contains "(aa) second verdict detail present" "$CONTENT_AA2" "Log: /tmp/foo.log"

# ─────────────────────────────────────────────────────────────────────────────
# (bb) relocate preserves the stepN_<slug> filename kind (not just _session.md).
# The kind suffix (everything after "<ts>_<old-slug>_") is carried over
# VERBATIM from the source file's own tail — relocate only swaps the leading
# slug segment. For a stepN kind, the tail itself embeds the old slug again
# (e.g. "step3_test-relocate-step-old.md"), which is pre-existing, unchanged
# behavior; this test locks in that the stepN_ branch (as opposed to the
# *_session.md branch already covered by case (y)) is exercised end-to-end.
WS_BB="$(new_workspace)"
TS_BB="$(date -u +%Y%m%d_%H%M%S)"
STEP_LOG_BB="$WS_BB/codegen/logging/${TS_BB}_step3_test-relocate-step-old.md"
cat >"$STEP_LOG_BB" <<'EOF'
## Version Stamp

- project: abc
EOF
printf '%s' "$STEP_LOG_BB" >"$WS_BB/codegen/logging/.active"
NEW_STEP_LOG_BB=$(env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_BB" \
    "$CODEGEN_LOG" relocate --new-slug test-relocate-step-new)
check "(bb) relocate returns a path starting with the timestamp + new slug" "0" \
    "$([[ "$(basename "$NEW_STEP_LOG_BB")" == "${TS_BB}_test-relocate-step-new_"* ]] && printf 0 || printf 1)"
check "(bb) relocate returns a path preserving the step3_ kind marker" "0" \
    "$([[ "$(basename "$NEW_STEP_LOG_BB")" == *"step3_"* ]] && printf 0 || printf 1)"
check "(bb) relocate returns a path ending in .md" "0" \
    "$([[ "$NEW_STEP_LOG_BB" == *.md ]] && printf 0 || printf 1)"
check "(bb) old step log no longer exists after relocate" "0" "$([ ! -f "$STEP_LOG_BB" ] && printf 0 || printf 1)"
check "(bb) new step log exists after relocate" "0" "$([ -f "$NEW_STEP_LOG_BB" ] && printf 0 || printf 1)"
check "(bb) .active sentinel rewritten to the new step log path" "$NEW_STEP_LOG_BB" "$(cat "$WS_BB/codegen/logging/.active")"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
