#!/bin/bash
# codegen-log_test.sh — unit tests for codegen-log
#
# Topology under test: PROJECT (downstream app cwd) != CODEGEN (script install
# dir). This reproduces the split-brain bug where codegen-log resolved logs
# relative to SCRIPT_DIR (the launcher's install dir) instead of the project
# cwd. A self-build fixture (cwd == codegen repo == SCRIPT_DIR) makes this bug
# invisible, so every fixture here uses two distinct roots.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_CODEGEN_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CODEGEN_LOG_SRC="$REAL_CODEGEN_ROOT/codegen-log"

pass=0
fail=0

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

make_stub() {
    local path="$1"
    local body="$2"
    printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
    chmod +x "$path"
}

assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        [ -n "${VERBOSE:-}" ] && printf 'PASS: %s\n' "$desc"
        pass=$((pass + 1))
    else
        printf 'FAIL: %s — expected %s, got %s\n' "$desc" "$expected" "$actual"
        fail=$((fail + 1))
    fi
}

# --- Two distinct roots: PROJECT (downstream app cwd) and CODEGEN (script's
# own install/repo dir). Both git-init'd separately so the git stub can
# branch on the -C argument and return distinct fake hashes per root.
PROJECT="$TMP_DIR/project"
CODEGEN="$TMP_DIR/codegen"
mkdir -p "$PROJECT/codegen/logging"
mkdir -p "$CODEGEN/codegen/rules"

cp "$CODEGEN_LOG_SRC" "$CODEGEN/codegen-log"
chmod +x "$CODEGEN/codegen-log"

STUB_BIN="$TMP_DIR/bin"
mkdir -p "$STUB_BIN"
# Git stub branches on the -C <dir> ARGUMENT, not $PWD, since after the fix
# all git -C calls happen from the same process cwd but target different
# roots (LOG_ROOT for project, CODEGEN_ROOT for codegen/codegen-rules).
make_stub "$STUB_BIN/git" '
if [ "$1" = "-C" ]; then
    dir="$2"
    shift 2
    if [ "$1" = "rev-parse" ] && [ "$2" = "--short" ] && [ "$3" = "HEAD" ]; then
        case "$dir" in
        */codegen/rules) printf "ctxabc\n" ;;
        *"'"$PROJECT"'") printf "proj123\n" ;;
        *"'"$CODEGEN"'") printf "cgn456\n" ;;
        *) printf "unknown\n" ;;
        esac
        exit 0
    fi
fi
command git "$@"
'
make_stub "$STUB_BIN/claude" 'printf "claude 1.2.3\n"'
export PATH="$STUB_BIN:$PATH"

# Test 1: init resolves the log root to the PROJECT cwd, not the CODEGEN
# script dir — even though the codegen-log binary itself lives in $CODEGEN.
# Unset CODEGEN_BUILD_CWD/CLAUDE_PROJECT_DIR: the ambient dev session that
# runs this test suite may have them set to the codegen repo itself, which
# would mask the bug this test exists to catch.
init_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug canonical)"
init_path="$(printf '%s' "$init_out" | tail -n 1)"
assert "init printed path" "0" "$([ -f "$init_path" ] && printf 0 || printf 1)"
case "$init_path" in
"$PROJECT/codegen/logging/"*) init_under_project=0 ;;
*) init_under_project=1 ;;
esac
assert "init landed under PROJECT/codegen/logging" "0" "$init_under_project"
assert "init did not leak into CODEGEN/codegen/logging" "0" "$([ ! -d "$CODEGEN/codegen/logging" ] || [ -z "$(ls -A "$CODEGEN/codegen/logging" 2>/dev/null)" ] && printf 0 || printf 1)"
assert "init wrote version stamp" "0" "$([ "$(grep -c '^## Version Stamp$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"
assert "init omitted plan header" "0" "$([ "$(grep -c '^## Plan$' "$init_path")" -eq 0 ] && printf 0 || printf 1)"
assert "init stamped project hash from PROJECT root" "0" "$([ "$(grep -c '^- project: proj123$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"
assert "init stamped codegen hash from CODEGEN root" "0" "$([ "$(grep -c '^- codegen: cgn456$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"
assert "init stamped context hash from CODEGEN/codegen/rules" "0" "$([ "$(grep -c '^- context: ctxabc$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"
assert "init stamped claude version" "0" "$([ "$(grep -c '^- claude: claude 1.2.3$' "$init_path")" -eq 1 ] && printf 0 || printf 1)"

# Test 2: section inserts developer body between Files Modified and reviewer,
# operating with cwd=PROJECT and the binary invoked from $CODEGEN.
fixture="$PROJECT/codegen/logging/fixture.md"
cat >"$fixture" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-06-29T00:00:00Z

## Plan

old plan

## Delegation Timeline

| Time | Agent | Task | Result |
| ---- | ----- | ---- | ------ |

## Files Modified

- a

## reviewer-phoenix Section

**Verdict**: QUALITY APPROVED ✅
EOF

export CODEGEN_LOG_PATH="$fixture"
unset AGENT_TYPE
section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend <<'EOF'
## developer-phoenix-backend Section

### What I Learned This Step
- inserted by test
EOF
)"
section_path="$(printf '%s' "$section_out" | tail -n 1)"
assert "section wrote target file" "0" "$([ "$section_path" = "$fixture" ] && printf 0 || printf 1)"
assert "section inserted developer header" "0" "$([ "$(grep -c '^## developer-phoenix-backend Section$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"
assert "section preserved reviewer header" "0" "$([ "$(grep -c '^## reviewer-phoenix Section$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"
assert "section landed before reviewer" "0" "$([ $(grep -n '^## developer-phoenix-backend Section$' "$fixture" | cut -d: -f1) -lt $(grep -n '^## reviewer-phoenix Section$' "$fixture" | cut -d: -f1) ] && printf 0 || printf 1)"
assert "section body preserved" "0" "$([ "$(grep -c '^### What I Learned This Step$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"

# Test 3: rerun replaces in place instead of duplicating the header.
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend <<'EOF'
## developer-phoenix-backend Section

### What I Learned This Step
- updated body
EOF
)

assert "rerun keeps one developer header" "0" "$([ "$(grep -c '^## developer-phoenix-backend Section$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"
assert "rerun updated body" "0" "$([ "$(grep -c '^- updated body$' "$fixture")" -eq 1 ] && printf 0 || printf 1)"

# Test 4: mktemp relocation — no stray .codegen-log-body.* temp file left
# under $CODEGEN (the script's own dir) after a section run. Proves the body
# temp file is rooted at TMPDIR, not SCRIPT_DIR.
stray_count="$(find "$CODEGEN" -maxdepth 2 -name '.codegen-log-body.*' 2>/dev/null | wc -l | tr -d ' ')"
assert "no stray body temp file under CODEGEN" "0" "$stray_count"

# Test 5: --slug targets a specific log by slug, not the most-recently-
# modified one. Two logs exist under PROJECT/codegen/logging; the OLDER one
# carries the target slug but is touched (mtime bumped) AFTER the newer one,
# so a naive latest-mtime fallback would pick the wrong file. --slug must
# still resolve to the slug-matching log.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
older_log="$PROJECT/codegen/logging/20260101_000000_older-slug_session.md"
newer_log="$PROJECT/codegen/logging/20260101_000100_newer-slug_session.md"
cat >"$older_log" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-01-01T00:00:00Z

## Plan

older plan
EOF
cat >"$newer_log" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-01-01T00:01:00Z

## Plan

newer plan
EOF
# Bump older_log's mtime AFTER newer_log's so a latest-mtime fallback would
# wrongly select older_log if --slug resolution were not honored.
touch "$older_log"

slug_section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section --role developer-phoenix-backend --slug newer-slug --body @- <<'EOF'
## developer-phoenix-backend Section

### What I Learned This Step
- targeted by slug, not by mtime
EOF
)"
slug_section_path="$(printf '%s' "$slug_section_out" | tail -n 1)"
assert "--slug wrote to the slug-matching log, not the most-recently-touched one" "0" "$([ "$slug_section_path" = "$newer_log" ] && printf 0 || printf 1)"
assert "--slug-targeted log got the developer section" "0" "$([ "$(grep -c '^## developer-phoenix-backend Section$' "$newer_log")" -eq 1 ] && printf 0 || printf 1)"
assert "--slug did not divert the write into the older (more-recently-touched) log" "0" "$([ "$(grep -c '^## developer-phoenix-backend Section$' "$older_log")" -eq 0 ] && printf 0 || printf 1)"

# Test 6: opaque-body ingest — a stray col-0 "## " (H2) line in an author body
# is indented so it can never be parsed as a canonical section header, while
# H3 retro markers and H1 titles stay untouched (still author-typed in P1).
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
opaque_log="$PROJECT/codegen/logging/20260102_000000_opaque-body_session.md"
cat >"$opaque_log" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-01-02T00:00:00Z
EOF

opaque_section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section --role developer-phoenix-backend --slug opaque-body --body @- <<'EOF'
## developer-phoenix-backend Section

prose before

## Fake Header

prose after

### What I Learned This Step

- learned x

# Step 1

end prose
EOF
)"
opaque_section_path="$(printf '%s' "$opaque_section_out" | tail -n 1)"
assert "opaque-body section wrote to the opaque-body log" "0" "$([ "$opaque_section_path" = "$opaque_log" ] && printf 0 || printf 1)"
assert "opaque-body stray H2 is indented, not col-0" "0" "$([ "$(grep -c '^## Fake Header$' "$opaque_log")" -eq 0 ] && printf 0 || printf 1)"
assert "opaque-body stray H2 present indented" "0" "$([ "$(grep -c '^  ## Fake Header$' "$opaque_log")" -eq 1 ] && printf 0 || printf 1)"
assert "opaque-body H3 retro marker stays col-0 (untouched)" "0" "$([ "$(grep -c '^### What I Learned This Step$' "$opaque_log")" -eq 1 ] && printf 0 || printf 1)"
assert "opaque-body H3 retro marker NOT indented" "0" "$([ "$(grep -c '^  ### What I Learned This Step$' "$opaque_log")" -eq 0 ] && printf 0 || printf 1)"
assert "opaque-body H1 title stays col-0 (untouched)" "0" "$([ "$(grep -c '^# Step 1$' "$opaque_log")" -eq 1 ] && printf 0 || printf 1)"

# Test 7: opaque-body ingest on the append path — same transform applied.
opaque_append_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug opaque-body --body @- <<'EOF'
appended prose

## Baz

more appended prose
EOF
)"
opaque_append_path="$(printf '%s' "$opaque_append_out" | tail -n 1)"
assert "opaque-body append wrote to the opaque-body log" "0" "$([ "$opaque_append_path" = "$opaque_log" ] && printf 0 || printf 1)"
assert "opaque-body appended stray H2 is indented, not col-0" "0" "$([ "$(grep -c '^## Baz$' "$opaque_log")" -eq 0 ] && printf 0 || printf 1)"
assert "opaque-body appended stray H2 present indented" "0" "$([ "$(grep -c '^  ## Baz$' "$opaque_log")" -eq 1 ] && printf 0 || printf 1)"

# Test 8: --learned/--died/--verdict emit byte-exact canonical marker blocks
# that the reader hooks (subagent-retrospective-guard, step-log-completeness,
# stop-cycle-guard) grep for verbatim.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
marker_log="$PROJECT/codegen/logging/20260103_000000_marker-flags_session.md"
cat >"$marker_log" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-01-03T00:00:00Z

## developer-phoenix-backend Section

body
EOF

learned_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --learned "- nothing notable"
)"
learned_path="$(printf '%s' "$learned_out" | tail -n 1)"
assert "--learned wrote to the marker-flags log" "0" "$([ "$learned_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--learned emits byte-exact retro header" "0" "$([ "$(grep -c '^### What I Learned This Step$' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"
assert "--learned emits the supplied text" "0" "$([ "$(grep -c '^- nothing notable$' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"

died_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --died interrupted --cause "timeout"
)"
died_path="$(printf '%s' "$died_out" | tail -n 1)"
assert "--died interrupted wrote to the marker-flags log" "0" "$([ "$died_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--died interrupted emits byte-exact marker" "0" "$([ "$(grep -cF '### INTERRUPTED ⚠️ — developer-phoenix-backend dropped (timeout); re-spawning (attempt N/2)' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --died aborted >/dev/null
assert "--died aborted emits byte-exact marker" "0" "$([ "$(grep -cF '### ABORTED 💀 — developer-phoenix-backend dropped twice; stage failed.' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --verdict clear >/dev/null
assert "--verdict clear emits ALL CLEAR emoji" "0" "$([ "$(grep -cF 'ALL CLEAR ✅' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --verdict failed >/dev/null
assert "--verdict failed emits FAILED emoji" "0" "$([ "$(grep -cF 'FAILED ❌' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --verdict inconclusive >/dev/null
assert "--verdict inconclusive emits INCONCLUSIVE emoji" "0" "$([ "$(grep -cF 'INCONCLUSIVE ⚠️' "$marker_log")" -eq 1 ] && printf 0 || printf 1)"

# Test 9: init writes the .active sentinel with the resolved absolute log path.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
sentinel_init_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug sentinel-test)"
sentinel_init_path="$(printf '%s' "$sentinel_init_out" | tail -n 1)"
sentinel_file="$PROJECT/codegen/logging/.active"
assert "init writes .active sentinel" "0" "$([ -f "$sentinel_file" ] && printf 0 || printf 1)"
assert ".active sentinel contains the resolved log path" "0" "$([ "$(cat "$sentinel_file")" = "$sentinel_init_path" ] && printf 0 || printf 1)"

# Test 10: positional role resolves for section/append with implicit stdin.
positional_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend <<'EOF'
positional stdin body
EOF
)"
positional_path="$(printf '%s' "$positional_out" | tail -n 1)"
assert "positional section wrote to the sentinel-resolved log" "0" "$([ "$positional_path" = "$sentinel_init_path" ] && printf 0 || printf 1)"
assert "positional section body landed" "0" "$([ "$(grep -c 'positional stdin body' "$sentinel_init_path")" -eq 1 ] && printf 0 || printf 1)"

# Test 11: .active sentinel precedence over a more-recently-touched log.
older_touch_log="$PROJECT/codegen/logging/20260104_000000_older-touch_session.md"
cat >"$older_touch_log" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-01-04T00:00:00Z
EOF
touch "$older_touch_log"
sentinel_precedence_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append developer-phoenix-backend <<'EOF'
via sentinel not mtime
EOF
)"
sentinel_precedence_path="$(printf '%s' "$sentinel_precedence_out" | tail -n 1)"
assert "sentinel precedence honored over touched log" "0" "$([ "$sentinel_precedence_path" = "$sentinel_init_path" ] && printf 0 || printf 1)"

# Test 12: relocate renames the log and rewrites .active.
relocate_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" relocate --new-slug sentinel-test-renamed)"
relocate_path="$(printf '%s' "$relocate_out" | tail -n 1)"
case "$relocate_path" in
*_sentinel-test-renamed_session.md) relocate_slug_ok=0 ;;
*) relocate_slug_ok=1 ;;
esac
assert "relocate returns a path with the new slug" "0" "$relocate_slug_ok"
assert "relocate old path no longer exists" "0" "$([ ! -f "$sentinel_init_path" ] && printf 0 || printf 1)"
assert "relocate new path exists" "0" "$([ -f "$relocate_path" ] && printf 0 || printf 1)"
assert "relocate rewrote .active to the new path" "0" "$([ "$(cat "$sentinel_file")" = "$relocate_path" ] && printf 0 || printf 1)"

# Test 13: `verdict` writes the byte-exact "## dev-gate Section" block (the
# phoenix-dev-gate.sh sole-writer routing target) and APPENDS a new block on
# each call rather than replacing a prior one.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
verdict_log="$PROJECT/codegen/logging/20260105_000000_verdict-subcommand_session.md"
cat >"$verdict_log" <<'EOF'
## Version Stamp

- project: proj123
- context: ctxabc
- codegen: cgn456
- claude: claude 1.2.3
- stamped_at: 2026-01-05T00:00:00Z
EOF

verdict_out1="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" \
        verdict --gate "make test" --mode short --result "ALL CLEAR ✅" --slug verdict-subcommand
)"
verdict_path1="$(printf '%s' "$verdict_out1" | tail -n 1)"
assert "verdict wrote to the verdict-subcommand log" "0" "$([ "$verdict_path1" = "$verdict_log" ] && printf 0 || printf 1)"
assert "verdict emits dev-gate Section header" "0" "$([ "$(grep -c '^## dev-gate Section$' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "verdict emits Gate: line" "0" "$([ "$(grep -c '^Gate: make test$' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "verdict emits Ran: line" "0" "$([ "$(grep -c '^Ran: make test$' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "verdict emits Rules loaded line" "0" "$([ "$(grep -cF '**Rules loaded**: deterministic hook (dev-gate.sh) — no rules loaded' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "verdict emits Commands executed table header" "0" "$([ "$(grep -cF '**Commands executed**:' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "verdict emits table column header row" "0" "$([ "$(grep -cF '| Time (HH:MM:SS UTC) | Command | Exit | Notes |' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "verdict emits Result line" "0" "$([ "$(grep -cF '**Result**: ALL CLEAR ✅' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"

verdict_out2="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" \
        verdict --gate "make test" --mode short --result "FAILED ❌ exit=1" --detail "Log: /tmp/bar.log" --slug verdict-subcommand
)"
verdict_path2="$(printf '%s' "$verdict_out2" | tail -n 1)"
assert "second verdict call wrote to the same log" "0" "$([ "$verdict_path2" = "$verdict_log" ] && printf 0 || printf 1)"
assert "second verdict call APPENDS a new dev-gate Section (does not replace)" "0" "$([ "$(grep -c '^## dev-gate Section$' "$verdict_log")" -eq 2 ] && printf 0 || printf 1)"
assert "first verdict block's Result still present after second call" "0" "$([ "$(grep -cF '**Result**: ALL CLEAR ✅' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "second verdict block's Result present" "0" "$([ "$(grep -cF '**Result**: FAILED ❌ exit=1' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"
assert "second verdict block's detail present" "0" "$([ "$(grep -cF 'Log: /tmp/bar.log' "$verdict_log")" -eq 1 ] && printf 0 || printf 1)"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
