#!/usr/bin/env bash
# codegen-log_test.sh — unit tests for codegen-log (init / section / append),
# JSONL cycle-log storage.
#
# Cases:
# (a) --role override yields correct role event, ignoring ambient AGENT_TYPE/CLAUDE_ROLE
# (b) empty-body `section --role <role>` still appends a role event
# (c) `append --role <role>` preserves prior role event and adds the new body in order
# (e) unsupported `--role foo` exits 2, error names --role remedy
# (g) `init` is idempotent: re-init on an existing slug prints the same path;
#     a distinct slug forks a new log
# (h) `--slug` resolves to the matching log among multiple logs in one workspace
# (i) `--slug` with zero matches exits 2 with "no cycle log matches slug"
# (j) `--slug` with multiple matches exits 2 with "ambiguous slug"
# (o) `section` plain-prose body passes through byte-identical (opaque string,
#     no re-parsing as markdown structure — the whole class of stray-H2
#     indenting logic is gone under JSONL)
# (r) append --learned emits a structured learned event
# (s) append --died interrupted/aborted emits structured died events
# (t) append --verdict clear|failed|inconclusive emits structured gate events
# (u) --learned/--died/--verdict are mutually exclusive with each other;
#     --died/--verdict are append-only; --learned+--body are mutually
#     exclusive on append (but --learned is valid ALONGSIDE --body on section)
# (v) init writes the .active sentinel with the resolved absolute log path
# (w) positional role resolves for section/append; implicit stdin (no --body)
# (x) .active sentinel precedence over a more-recently-touched log
# (y) relocate renames the log file (preserving _cycle.jsonl suffix) and
#     rewrites .active to the new path
# (aa) `verdict` writes a structured "gate" event (role=dev-gate), and
#      repeated calls APPEND a fresh event each time rather than replacing
#      the prior one (dev-gate re-runs across retries must all remain visible)
# (bb) `section <role> --learned "<text>"` emits BOTH a "role" event and a
#      "learned" event in one call; `section` without --learned emits only
#      the "role" event and NEVER refuses the write

set -euo pipefail

# Every case below builds its own explicit workspace + log path and must never
# inherit an ambient CODEGEN_LOG_PATH from the invoking shell (e.g. a live
# developer session working on codegen-log/orchestration-loop pitches, which
# legitimately exports CODEGEN_LOG_PATH pointing at its OWN active cycle log).
# CODEGEN_LOG_PATH is codegen-log's highest-precedence resolver — left set, it
# silently redirects every `section`/`append` call below into that unrelated
# log instead of the per-case tmp workspace, which then reads back your own
# cycle log's role/body events. Unsetting once here is exhaustive; scrubbing
# every individual `env -u ...` call site is not (this file also runs several
# calls without an explicit `env -u` wrapper at all).
unset CODEGEN_LOG_PATH

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

# jq_count <file> <jq-select-expr> — count matching JSONL lines.
jq_count() {
    local file="$1" expr="$2"
    jq -c "$expr" "$file" 2>/dev/null | grep -c . || true
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
# (a) --role override yields correct role event, ignoring ambient env
WS_A="$(new_workspace)"
LOG_A="$(init_log "$WS_A" test-role-override)"
OUT_A=$(printf 'body a\n' | env -u AGENT_TYPE -u CODEGEN_LOG_PATH CLAUDE_ROLE=committer \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_A" \
    "$CODEGEN_LOG" section --role reviewer-phoenix --body @-)
check "(a) --role override appends a reviewer-phoenix role event, not committer" "1" "$(jq_count "$LOG_A" 'select(.ev=="role" and .role=="reviewer-phoenix")')"
check "(a) committer role event NOT inserted (env ignored)" "0" "$(jq_count "$LOG_A" 'select(.ev=="role" and .role=="committer")')"

# ─────────────────────────────────────────────────────────────────────────────
# (b) empty-body `section --role <role>` still appends a role event
WS_B="$(new_workspace)"
LOG_B="$(init_log "$WS_B" test-empty-open)"
printf '' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_B" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
check "(b) empty-body section appends a developer-phoenix-backend role event" "1" "$(jq_count "$LOG_B" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"

# ─────────────────────────────────────────────────────────────────────────────
# (c) append preserves prior role event, adds new one in order
WS_C="$(new_workspace)"
LOG_C="$(init_log "$WS_C" test-append-order)"
printf 'ORIGINAL BODY LINE\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_C" \
    "$CODEGEN_LOG" section --role reviewer-phoenix --body @- >/dev/null
printf 'SECOND BODY LINE\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_C" \
    "$CODEGEN_LOG" append --role reviewer-phoenix --body @- >/dev/null
check "(c) append appends a second reviewer-phoenix role event" "2" "$(jq_count "$LOG_C" 'select(.ev=="role" and .role=="reviewer-phoenix")')"
ORIG_IDX=$(grep -n "ORIGINAL BODY LINE" "$LOG_C" | cut -d: -f1)
SECOND_IDX=$(grep -n "SECOND BODY LINE" "$LOG_C" | cut -d: -f1)
ORDER_OK=0
[ "$ORIG_IDX" -lt "$SECOND_IDX" ] && ORDER_OK=1
check "(c) original body precedes appended body" "1" "$ORDER_OK"

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
# (i) --slug with zero matches exits 2 with "no cycle log matches slug"
WS_I="$(new_workspace)"
init_log "$WS_I" some-other-slug >/dev/null
set +e
ERR_I=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_I" \
    "$CODEGEN_LOG" section --role committer --slug missing-slug --body @- 2>&1)
RC_I=$?
set -e
check "(i) --slug zero-match exits 2" "2" "$RC_I"
assert_contains "(i) --slug zero-match error message" "$ERR_I" "no cycle log matches slug"

# ─────────────────────────────────────────────────────────────────────────────
# (j) --slug with multiple matches exits 2 with "ambiguous slug"
WS_J="$(new_workspace)"
touch "$WS_J/codegen/logging/20260101_000001_dup_cycle.jsonl"
touch "$WS_J/codegen/logging/20260101_000002_dup_cycle.jsonl"
set +e
ERR_J=$(printf 'x\n' | env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_J" \
    "$CODEGEN_LOG" section --role committer --slug dup --body @- 2>&1)
RC_J=$?
set -e
check "(j) --slug many-match exits 2" "2" "$RC_J"
assert_contains "(j) --slug many-match error message" "$ERR_J" "ambiguous slug"

# ─────────────────────────────────────────────────────────────────────────────
# (o) section: plain-prose body passes through byte-identical (opaque string
# under JSONL — no re-parsing as markdown, so no indenting/mangling exists)
WS_O="$(new_workspace)"
LOG_O="$(init_log "$WS_O" test-opaque-prose-passthrough)"
printf 'just plain prose\nwith multiple lines\nno structural markers\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_O" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
BODY_O="$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$LOG_O")"
assert_contains "(o) plain prose passes through unchanged" "$BODY_O" $'just plain prose\nwith multiple lines\nno structural markers'

# ─────────────────────────────────────────────────────────────────────────────
# (o2) section: a body containing a stray "## Fake Header" line passes through
# verbatim, never promoted to structure — the whole indent-mangling mechanism
# is gone under JSONL (a body is just an opaque JSON string value).
WS_O2="$(new_workspace)"
LOG_O2="$(init_log "$WS_O2" test-opaque-stray-h2)"
printf 'prose before\n\n## Fake Header\n\nprose after\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_O2" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
BODY_O2="$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$LOG_O2")"
assert_contains "(o2) stray H2 preserved verbatim in body (no indent-mangling)" "$BODY_O2" "## Fake Header"

# ─────────────────────────────────────────────────────────────────────────────
# (r) append --learned emits a structured learned event.
WS_R="$(new_workspace)"
LOG_R="$(init_log "$WS_R" test-learned-marker)"
printf 'body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_R" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_R" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --learned "- nothing notable" >/dev/null
check "(r) --learned emits exactly one learned event" "1" "$(jq_count "$LOG_R" 'select(.ev=="learned" and .role=="developer-phoenix-backend")')"
check "(r) --learned emits the supplied text" "- nothing notable" "$(jq -r 'select(.ev=="learned")|.text' "$LOG_R")"

# ─────────────────────────────────────────────────────────────────────────────
# (s) append --died interrupted/aborted emits structured died events.
WS_S="$(new_workspace)"
LOG_S="$(init_log "$WS_S" test-died-marker)"
printf 'body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_S" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_S" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --died interrupted --cause "timeout" >/dev/null
check "(s) --died interrupted emits a died event" "1" "$(jq_count "$LOG_S" 'select(.ev=="died" and .kind=="interrupted")')"
check "(s) --died interrupted carries the cause" "timeout" "$(jq -r 'select(.ev=="died" and .kind=="interrupted")|.cause' "$LOG_S")"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_S" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --died aborted >/dev/null
check "(s) --died aborted emits a died event" "1" "$(jq_count "$LOG_S" 'select(.ev=="died" and .kind=="aborted")')"

# ─────────────────────────────────────────────────────────────────────────────
# (t) append --verdict clear|failed|inconclusive emits structured gate events.
WS_T="$(new_workspace)"
LOG_T="$(init_log "$WS_T" test-verdict-marker)"
printf 'body\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" section --role developer-phoenix-backend --body @- >/dev/null
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --verdict clear >/dev/null
check "(t) --verdict clear emits gate event verdict=clear" "1" "$(jq_count "$LOG_T" 'select(.ev=="gate" and .verdict=="clear")')"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --verdict failed >/dev/null
check "(t) --verdict failed emits gate event verdict=failed" "1" "$(jq_count "$LOG_T" 'select(.ev=="gate" and .verdict=="failed")')"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_T" \
    "$CODEGEN_LOG" append --role developer-phoenix-backend --verdict inconclusive >/dev/null
check "(t) --verdict inconclusive emits gate event verdict=inconclusive" "1" "$(jq_count "$LOG_T" 'select(.ev=="gate" and .verdict=="inconclusive")')"

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
    "$CODEGEN_LOG" append --role committer --learned "x" --body @- 2>&1)
RC_U2=$?
set -e
check "(u) --learned + --body on append exits 2" "2" "$RC_U2"
assert_contains "(u) --learned+--body mutual-exclusivity error message" "$ERR_U2" "mutually exclusive"

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
# (y) relocate renames the log file (preserving _cycle.jsonl suffix) and
# rewrites .active to the new path.
WS_Y="$(new_workspace)"
LOG_Y="$(init_log "$WS_Y" test-relocate-old)"
RELOCATE_OUT_Y=$(env -u AGENT_TYPE -u CLAUDE_ROLE -u CODEGEN_LOG_PATH \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_Y" \
    "$CODEGEN_LOG" relocate --new-slug test-relocate-new)
NEW_LOG_Y=$(printf '%s' "$RELOCATE_OUT_Y" | tail -n 1)
check "(y) relocate returns a path ending in the new slug + _cycle.jsonl" "0" "$([[ "$NEW_LOG_Y" == *_test-relocate-new_cycle.jsonl ]] && printf 0 || printf 1)"
check "(y) old log path no longer exists after relocate" "0" "$([ ! -f "$LOG_Y" ] && printf 0 || printf 1)"
check "(y) new log path exists after relocate" "0" "$([ -f "$NEW_LOG_Y" ] && printf 0 || printf 1)"
check "(y) .active sentinel rewritten to the new path" "$NEW_LOG_Y" "$(cat "$WS_Y/codegen/logging/.active")"

# ─────────────────────────────────────────────────────────────────────────────
# (z) bare positional-less section/append with no --role and no ambient env
# still exits 2 with a clear error naming both remedies (positional + --role);
# ambient env vars (AGENT_TYPE/CLAUDE_ROLE) are NEVER consulted.
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
# (aa) `verdict` writes a structured gate event (role=dev-gate), and repeated
# calls APPEND a fresh event each time rather than replacing the prior one
# (dev-gate re-runs across retries must all remain visible).
WS_AA="$(new_workspace)"
LOG_AA="$(init_log "$WS_AA" test-verdict-subcommand)"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_AA" \
    "$CODEGEN_LOG" verdict --gate "make test" --mode short --result "ALL CLEAR ✅" >/dev/null
check "(aa) verdict emits exactly one gate event" "1" "$(jq_count "$LOG_AA" 'select(.ev=="gate" and .role=="dev-gate")')"
check "(aa) verdict derives verdict=clear" "clear" "$(jq -r 'select(.ev=="gate")|.verdict' "$LOG_AA")"
check "(aa) verdict carries gate command" "make test" "$(jq -r 'select(.ev=="gate")|.gate' "$LOG_AA")"
check "(aa) verdict carries mode" "short" "$(jq -r 'select(.ev=="gate")|.mode' "$LOG_AA")"
check "(aa) verdict carries raw result text" "ALL CLEAR ✅" "$(jq -r 'select(.ev=="gate")|.result' "$LOG_AA")"
env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_AA" \
    "$CODEGEN_LOG" verdict --gate "make test" --mode short --result "FAILED ❌ exit=1" --detail "Log: /tmp/foo.log" >/dev/null
check "(aa) second verdict call appends a NEW gate event (does not replace)" "2" "$(jq_count "$LOG_AA" 'select(.ev=="gate" and .role=="dev-gate")')"
check "(aa) first verdict event still present after second call" "1" "$(jq_count "$LOG_AA" 'select(.ev=="gate" and .result=="ALL CLEAR ✅")')"
check "(aa) second verdict event derives verdict=failed" "1" "$(jq_count "$LOG_AA" 'select(.ev=="gate" and .verdict=="failed")')"
check "(aa) second verdict event's detail present" "Log: /tmp/foo.log" "$(jq -r 'select(.ev=="gate" and .verdict=="failed")|.detail' "$LOG_AA")"

# ─────────────────────────────────────────────────────────────────────────────
# (bb) `section <role> --learned "<text>"` emits BOTH an "ev":"role" event
# (from --body) AND an "ev":"learned" event, in one call. `section` without
# --learned emits exactly one "ev":"role" event and zero "ev":"learned"
# events — section NEVER refuses a write.
WS_BB="$(new_workspace)"
LOG_BB="$(init_log "$WS_BB" test-section-learned)"
printf 'did the work\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_BB" \
    "$CODEGEN_LOG" section committer --learned "learned something useful this step" >/dev/null
check "(bb) section --learned emits exactly one role event" "1" "$(jq_count "$LOG_BB" 'select(.ev=="role" and .role=="committer")')"
check "(bb) section --learned emits exactly one learned event" "1" "$(jq_count "$LOG_BB" 'select(.ev=="learned" and .role=="committer")')"
check "(bb) role event body is the piped stdin" "did the work" "$(jq -r 'select(.ev=="role")|.body' "$LOG_BB")"
check "(bb) learned event text matches --learned" "learned something useful this step" "$(jq -r 'select(.ev=="learned")|.text' "$LOG_BB")"

WS_BB2="$(new_workspace)"
LOG_BB2="$(init_log "$WS_BB2" test-section-no-learned)"
printf 'no learned flag here\n' | env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_BB2" \
    "$CODEGEN_LOG" section committer >/dev/null
check "(bb) section without --learned emits exactly one role event" "1" "$(jq_count "$LOG_BB2" 'select(.ev=="role" and .role=="committer")')"
check "(bb) section without --learned emits zero learned events (never refuses)" "0" "$(jq_count "$LOG_BB2" 'select(.ev=="learned")')"

# ─────────────────────────────────────────────────────────────────────────────
# (cc) init refuses (exit 2) when CODEGEN_LOG_PATH is set — creates no new
# file and leaves .active byte-identical. Also proves the resolver-side fix:
# a guard resolving via CODEGEN_LOG_PATH still lands on the REAL pinned log
# even though a same-process init-under-pin attempt was made and rejected —
# this is the exact hijack this pitch closes (cycle-20260714_182153).
WS_CC="$(new_workspace)"
LOG_CC="$(init_log "$WS_CC" test-pin-refusal)"
ACTIVE_CC="$WS_CC/codegen/logging/.active"
ACTIVE_BEFORE_CC="$(cat "$ACTIVE_CC")"
FILES_BEFORE_CC="$(find "$WS_CC/codegen/logging" -name '*_cycle.jsonl' | sort)"
set +e
ERR_CC=$(env -u AGENT_TYPE -u CLAUDE_ROLE \
    OCG_CODEGEN_DIR="$CODEGEN_ROOT" CODEGEN_BUILD_CWD="$WS_CC" CODEGEN_LOG_PATH="$LOG_CC" \
    "$CODEGEN_LOG" init --slug rival-typo-slug 2>&1)
RC_CC=$?
set -e
check "(cc) init under CODEGEN_LOG_PATH pin exits 2" "2" "$RC_CC"
assert_contains "(cc) refusal message names the pinned path" "$ERR_CC" "$LOG_CC"
FILES_AFTER_CC="$(find "$WS_CC/codegen/logging" -name '*_cycle.jsonl' | sort)"
check "(cc) refusal created no new *_cycle.jsonl file" "$FILES_BEFORE_CC" "$FILES_AFTER_CC"
check "(cc) refusal left .active byte-identical" "$ACTIVE_BEFORE_CC" "$(cat "$ACTIVE_CC")"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
exit 0
