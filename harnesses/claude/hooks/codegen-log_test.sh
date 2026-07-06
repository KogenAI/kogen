#!/bin/bash
# codegen-log_test.sh — unit tests for codegen-log (JSONL cycle-log storage)
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

# jq_count <file> <jq-select-expr> — count matching JSONL lines.
jq_count() {
    local file="$1" expr="$2"
    jq -c "$expr" "$file" 2>/dev/null | grep -c . || true
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
case "$init_path" in
*_cycle.jsonl) init_ext_ok=0 ;;
*) init_ext_ok=1 ;;
esac
assert "init filename ends with _cycle.jsonl" "0" "$init_ext_ok"
assert "init wrote exactly one line" "1" "$(wc -l <"$init_path" | tr -d ' ')"
assert "init line is a valid init event" "0" "$(jq -e '.ev == "init"' "$init_path" >/dev/null 2>&1 && printf 0 || printf 1)"
assert "init stamped pitch=slug" "0" "$([ "$(jq -r '.pitch' "$init_path")" = "canonical" ] && printf 0 || printf 1)"
assert "init stamped project hash from PROJECT root" "0" "$([ "$(jq -r '.stamp.project' "$init_path")" = "proj123" ] && printf 0 || printf 1)"
assert "init stamped codegen hash from CODEGEN root" "0" "$([ "$(jq -r '.stamp.codegen' "$init_path")" = "cgn456" ] && printf 0 || printf 1)"
assert "init stamped context hash from CODEGEN/codegen/rules" "0" "$([ "$(jq -r '.stamp.context' "$init_path")" = "ctxabc" ] && printf 0 || printf 1)"
assert "init stamped claude version" "0" "$([ "$(jq -r '.stamp.claude' "$init_path")" = "claude 1.2.3" ] && printf 0 || printf 1)"

# Test 2: section appends a "role" event with the given role + body,
# operating with cwd=PROJECT and the binary invoked from $CODEGEN.
fixture="$PROJECT/codegen/logging/fixture.jsonl"
: >"$fixture"

export CODEGEN_LOG_PATH="$fixture"
unset AGENT_TYPE
section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend <<'EOF'
### What I Learned This Step
- inserted by test
EOF
)"
section_path="$(printf '%s' "$section_out" | tail -n 1)"
assert "section wrote target file" "0" "$([ "$section_path" = "$fixture" ] && printf 0 || printf 1)"
assert "section appended one role event" "1" "$(jq_count "$fixture" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
assert "section body preserved" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$fixture" | grep -qF 'inserted by test' && printf 0 || printf 1)"

# Test 3: rerun APPENDS a second role event — never overwrites/replaces.
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend <<'EOF'
### What I Learned This Step
- updated body
EOF
)

assert "rerun appends a second developer role event (append-not-overwrite)" "2" "$(jq_count "$fixture" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
assert "rerun new body present" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$fixture" | grep -qF 'updated body' && printf 0 || printf 1)"
assert "rerun original body still present (append preserved, not replaced)" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$fixture" | grep -qF 'inserted by test' && printf 0 || printf 1)"

# Test 4: mktemp/scratch relocation — no stray temp file left under $CODEGEN
# (the script's own dir) after a section run.
stray_count="$(find "$CODEGEN" -maxdepth 2 -name '.codegen-log-*' 2>/dev/null | wc -l | tr -d ' ')"
assert "no stray temp file under CODEGEN" "0" "$stray_count"

# Test 5: --slug targets a specific log by slug, not the most-recently-
# modified one. Two logs exist under PROJECT/codegen/logging; the OLDER one
# carries the target slug but is touched (mtime bumped) AFTER the newer one,
# so a naive latest-mtime fallback would pick the wrong file. --slug must
# still resolve to the slug-matching log.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
older_log="$PROJECT/codegen/logging/20260101_000000_older-slug_cycle.jsonl"
newer_log="$PROJECT/codegen/logging/20260101_000100_newer-slug_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"older-slug",path:"",stamp:{}}' >"$older_log"
jq -c -n '{ev:"init",pitch:"newer-slug",path:"",stamp:{}}' >"$newer_log"
# Bump older_log's mtime AFTER newer_log's so a latest-mtime fallback would
# wrongly select older_log if --slug resolution were not honored.
touch "$older_log"

slug_section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section --role developer-phoenix-backend --slug newer-slug --body @- <<'EOF'
targeted by slug, not by mtime
EOF
)"
slug_section_path="$(printf '%s' "$slug_section_out" | tail -n 1)"
assert "--slug wrote to the slug-matching log, not the most-recently-touched one" "0" "$([ "$slug_section_path" = "$newer_log" ] && printf 0 || printf 1)"
assert "--slug-targeted log got the developer role event" "1" "$(jq_count "$newer_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
assert "--slug did not divert the write into the older (more-recently-touched) log" "0" "$(jq_count "$older_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"

# Test 6: multi-line body preserved exactly across JSON string escaping,
# including a stray "## " (H2)-looking line — under JSONL, a body containing
# markdown-looking text is just an opaque string, never re-parsed as
# structure. No indent-mangling transform is needed or applied.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
opaque_log="$PROJECT/codegen/logging/20260102_000000_opaque-body_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"opaque-body",path:"",stamp:{}}' >"$opaque_log"

opaque_section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section --role developer-phoenix-backend --slug opaque-body --body @- <<'EOF'
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
assert "opaque-body line is valid JSON" "0" "$(tail -n 1 "$opaque_log" | jq -e '.ev == "role"' >/dev/null 2>&1 && printf 0 || printf 1)"
assert "opaque-body preserves stray H2 verbatim in body (no mangling)" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$opaque_log" | grep -qF '## Fake Header' && printf 0 || printf 1)"
assert "opaque-body preserves H3 retro marker in body" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$opaque_log" | grep -qF '### What I Learned This Step' && printf 0 || printf 1)"
assert "opaque-body preserves H1 title in body" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$opaque_log" | grep -qF '# Step 1' && printf 0 || printf 1)"

# Test 7: append with a plain --body appends another "role" event line.
opaque_append_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug opaque-body --body @- <<'EOF'
appended prose

## Baz

more appended prose
EOF
)"
opaque_append_path="$(printf '%s' "$opaque_append_out" | tail -n 1)"
assert "opaque-body append wrote to the opaque-body log" "0" "$([ "$opaque_append_path" = "$opaque_log" ] && printf 0 || printf 1)"
assert "opaque-body append is a second role event" "2" "$(jq_count "$opaque_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
assert "opaque-body appended stray H2 preserved verbatim" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$opaque_log" | grep -qF '## Baz' && printf 0 || printf 1)"

# Test 8: --learned/--died/--verdict emit structured events the reader hooks
# (subagent-retrospective-guard, step-log-completeness, stop-cycle-guard)
# jq-select for.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
marker_log="$PROJECT/codegen/logging/20260103_000000_marker-flags_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"marker-flags",path:"",stamp:{}}' >"$marker_log"
jq -c -n '{ev:"role",role:"developer-phoenix-backend",body:"body"}' >>"$marker_log"

learned_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --learned "- nothing notable"
)"
learned_path="$(printf '%s' "$learned_out" | tail -n 1)"
assert "--learned wrote to the marker-flags log" "0" "$([ "$learned_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--learned emits exactly one learned event" "1" "$(jq_count "$marker_log" 'select(.ev=="learned" and .role=="developer-phoenix-backend")')"
assert "--learned emits the supplied text" "0" "$([ "$(jq -r 'select(.ev=="learned")|.text' "$marker_log")" = "- nothing notable" ] && printf 0 || printf 1)"

died_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --died interrupted --cause "timeout"
)"
died_path="$(printf '%s' "$died_out" | tail -n 1)"
assert "--died interrupted wrote to the marker-flags log" "0" "$([ "$died_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--died interrupted emits a died event with kind=interrupted" "1" "$(jq_count "$marker_log" 'select(.ev=="died" and .kind=="interrupted")')"
assert "--died interrupted carries the cause" "0" "$([ "$(jq -r 'select(.ev=="died" and .kind=="interrupted")|.cause' "$marker_log")" = "timeout" ] && printf 0 || printf 1)"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --died aborted >/dev/null
assert "--died aborted emits a died event with kind=aborted" "1" "$(jq_count "$marker_log" 'select(.ev=="died" and .kind=="aborted")')"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --verdict clear >/dev/null
assert "--verdict clear emits gate event with verdict=clear" "1" "$(jq_count "$marker_log" 'select(.ev=="gate" and .verdict=="clear")')"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --verdict failed >/dev/null
assert "--verdict failed emits gate event with verdict=failed" "1" "$(jq_count "$marker_log" 'select(.ev=="gate" and .verdict=="failed")')"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --verdict inconclusive >/dev/null
assert "--verdict inconclusive emits gate event with verdict=inconclusive" "1" "$(jq_count "$marker_log" 'select(.ev=="gate" and .verdict=="inconclusive")')"

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
assert "positional section body landed" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$sentinel_init_path" | grep -qF 'positional stdin body' && printf 0 || printf 1)"

# Test 11: .active sentinel precedence over a more-recently-touched log.
older_touch_log="$PROJECT/codegen/logging/20260104_000000_older-touch_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"older-touch",path:"",stamp:{}}' >"$older_touch_log"
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
*_sentinel-test-renamed_cycle.jsonl) relocate_slug_ok=0 ;;
*) relocate_slug_ok=1 ;;
esac
assert "relocate returns a path with the new slug" "0" "$relocate_slug_ok"
assert "relocate old path no longer exists" "0" "$([ ! -f "$sentinel_init_path" ] && printf 0 || printf 1)"
assert "relocate new path exists" "0" "$([ -f "$relocate_path" ] && printf 0 || printf 1)"
assert "relocate rewrote .active to the new path" "0" "$([ "$(cat "$sentinel_file")" = "$relocate_path" ] && printf 0 || printf 1)"

# Test 13: `verdict` appends a "gate" event (role="dev-gate") — the
# phoenix-dev-gate.sh sole-writer routing target — and APPENDS a new event on
# each call rather than replacing a prior one.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
verdict_log="$PROJECT/codegen/logging/20260105_000000_verdict-subcommand_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"verdict-subcommand",path:"",stamp:{}}' >"$verdict_log"

verdict_out1="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" \
        verdict --gate "make test" --mode short --result "ALL CLEAR ✅" --slug verdict-subcommand
)"
verdict_path1="$(printf '%s' "$verdict_out1" | tail -n 1)"
assert "verdict wrote to the verdict-subcommand log" "0" "$([ "$verdict_path1" = "$verdict_log" ] && printf 0 || printf 1)"
assert "verdict emits exactly one gate event (role=dev-gate)" "1" "$(jq_count "$verdict_log" 'select(.ev=="gate" and .role=="dev-gate")')"
assert "verdict derives verdict=clear from ALL CLEAR result text" "0" "$([ "$(jq -r 'select(.ev=="gate")|.verdict' "$verdict_log")" = "clear" ] && printf 0 || printf 1)"
assert "verdict carries gate command" "0" "$([ "$(jq -r 'select(.ev=="gate")|.gate' "$verdict_log")" = "make test" ] && printf 0 || printf 1)"
assert "verdict carries mode" "0" "$([ "$(jq -r 'select(.ev=="gate")|.mode' "$verdict_log")" = "short" ] && printf 0 || printf 1)"
assert "verdict carries raw result text" "0" "$([ "$(jq -r 'select(.ev=="gate")|.result' "$verdict_log")" = "ALL CLEAR ✅" ] && printf 0 || printf 1)"

verdict_out2="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" \
        verdict --gate "make test" --mode short --result "FAILED ❌ exit=1" --detail "Log: /tmp/bar.log" --slug verdict-subcommand
)"
verdict_path2="$(printf '%s' "$verdict_out2" | tail -n 1)"
assert "second verdict call wrote to the same log" "0" "$([ "$verdict_path2" = "$verdict_log" ] && printf 0 || printf 1)"
assert "second verdict call APPENDS a new gate event (does not replace)" "2" "$(jq_count "$verdict_log" 'select(.ev=="gate" and .role=="dev-gate")')"
assert "first verdict event's result still present after second call" "1" "$(jq_count "$verdict_log" 'select(.ev=="gate" and .result=="ALL CLEAR ✅")')"
assert "second verdict event derives verdict=failed" "1" "$(jq_count "$verdict_log" 'select(.ev=="gate" and .verdict=="failed")')"
assert "second verdict event's detail present" "0" "$([ "$(jq -r 'select(.ev=="gate" and .verdict=="failed")|.detail' "$verdict_log")" = "Log: /tmp/bar.log" ] && printf 0 || printf 1)"

# Test 14: root resolution from CODEGEN_DIR / OCG_CODEGEN_DIR when the
# copy has NO sibling `codegen/` dir (the ~/.local/bin install shape).
# NOWHERE_DIR has no `codegen` subdir alongside the copied binary, so the
# sibling-check fallback is forced to consult the env vars.
NOWHERE_DIR="$TMP_DIR/nowhere"
mkdir -p "$NOWHERE_DIR"
cp "$CODEGEN_LOG_SRC" "$NOWHERE_DIR/codegen-log"
chmod +x "$NOWHERE_DIR/codegen-log"

# 14a: CODEGEN_DIR set (git-stubbed CODEGEN root) -> real hashes.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
env_root_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR -u OCG_CODEGEN_DIR \
        CODEGEN_DIR="$CODEGEN" \
        "$NOWHERE_DIR/codegen-log" init --slug env-root-codegen-dir
)"
env_root_path="$(printf '%s' "$env_root_out" | tail -n 1)"
assert "CODEGEN_DIR resolves codegen hash" "0" "$([ "$(jq -r '.stamp.codegen' "$env_root_path")" = "cgn456" ] && printf 0 || printf 1)"
assert "CODEGEN_DIR resolves context hash" "0" "$([ "$(jq -r '.stamp.context' "$env_root_path")" = "ctxabc" ] && printf 0 || printf 1)"

# 14b: OCG_CODEGEN_DIR set (no CODEGEN_DIR) -> same real hashes.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
ocg_root_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR -u CODEGEN_DIR \
        OCG_CODEGEN_DIR="$CODEGEN" \
        "$NOWHERE_DIR/codegen-log" init --slug env-root-ocg-codegen-dir
)"
ocg_root_path="$(printf '%s' "$ocg_root_out" | tail -n 1)"
assert "OCG_CODEGEN_DIR resolves codegen hash" "0" "$([ "$(jq -r '.stamp.codegen' "$ocg_root_path")" = "cgn456" ] && printf 0 || printf 1)"
assert "OCG_CODEGEN_DIR resolves context hash" "0" "$([ "$(jq -r '.stamp.context' "$ocg_root_path")" = "ctxabc" ] && printf 0 || printf 1)"

# 14c: both set -> CODEGEN_DIR takes documented precedence. Build a second,
# distinct git-stubbed root (CODEGEN2) so precedence is provable — if
# OCG_CODEGEN_DIR won instead, the hash would be cgn789, not cgn456.
CODEGEN2="$TMP_DIR/codegen2"
mkdir -p "$CODEGEN2/codegen/rules"
make_stub "$STUB_BIN/git" '
if [ "$1" = "-C" ]; then
    dir="$2"
    shift 2
    if [ "$1" = "rev-parse" ] && [ "$2" = "--short" ] && [ "$3" = "HEAD" ]; then
        case "$dir" in
        */codegen/rules)
            case "$dir" in
            *"'"$CODEGEN2"'"*) printf "ctx789\n" ;;
            *) printf "ctxabc\n" ;;
            esac
            ;;
        *"'"$PROJECT"'") printf "proj123\n" ;;
        *"'"$CODEGEN2"'") printf "cgn789\n" ;;
        *"'"$CODEGEN"'") printf "cgn456\n" ;;
        *) printf "unknown\n" ;;
        esac
        exit 0
    fi
fi
command git "$@"
'
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
precedence_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR \
        CODEGEN_DIR="$CODEGEN" \
        OCG_CODEGEN_DIR="$CODEGEN2" \
        "$NOWHERE_DIR/codegen-log" init --slug env-root-precedence
)"
precedence_path="$(printf '%s' "$precedence_out" | tail -n 1)"
assert "CODEGEN_DIR takes precedence over OCG_CODEGEN_DIR when both set" "0" "$([ "$(jq -r '.stamp.codegen' "$precedence_path")" = "cgn456" ] && printf 0 || printf 1)"
assert "precedence: OCG_CODEGEN_DIR hash NOT used" "0" "$([ "$(jq -r '.stamp.codegen' "$precedence_path")" != "cgn789" ] && printf 0 || printf 1)"

# 14d: NEITHER set + no sibling codegen/ -> unresolved-root marker, init
# still exits 0, log still lands under PROJECT cwd, project: still stamped.
# RED-then-GREEN: before the codegen-log root-resolution fix, this case
# ran `git -C ""` and printed the misleading `unknown` for BOTH fields
# instead of the honest `unresolved-root` marker.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
unresolved_rc=0
unresolved_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR -u CODEGEN_DIR -u OCG_CODEGEN_DIR \
        "$NOWHERE_DIR/codegen-log" init --slug unresolved-root-case
)" || unresolved_rc=$?
unresolved_path="$(printf '%s' "$unresolved_out" | tail -n 1)"
assert "unresolved-root init still exits 0" "0" "$unresolved_rc"
assert "unresolved-root marker for context" "0" "$([ "$(jq -r '.stamp.context' "$unresolved_path")" = "unresolved-root" ] && printf 0 || printf 1)"
assert "unresolved-root marker for codegen" "0" "$([ "$(jq -r '.stamp.codegen' "$unresolved_path")" = "unresolved-root" ] && printf 0 || printf 1)"
assert "unresolved-root does NOT print misleading unknown for codegen" "0" "$([ "$(jq -r '.stamp.codegen' "$unresolved_path")" != "unknown" ] && printf 0 || printf 1)"
case "$unresolved_path" in
"$PROJECT/codegen/logging/"*) unresolved_under_project=0 ;;
*) unresolved_under_project=1 ;;
esac
assert "unresolved-root log still lands under PROJECT/codegen/logging" "0" "$unresolved_under_project"
assert "unresolved-root project hash still stamped from LOG_ROOT" "0" "$([ "$(jq -r '.stamp.project' "$unresolved_path")" = "proj123" ] && printf 0 || printf 1)"

# Test 15: --version exits 0 and prints a non-empty token.
version_rc=0
version_out="$(env -u CODEGEN_DIR -u OCG_CODEGEN_DIR "$NOWHERE_DIR/codegen-log" --version)" || version_rc=$?
assert "--version exits 0" "0" "$version_rc"
assert "--version prints a non-empty token" "0" "$([ -n "$version_out" ] && printf 0 || printf 1)"
assert "--version reports unresolved-root when neither env var set nor sibling present" "0" "$(printf '%s' "$version_out" | grep -qF 'unresolved-root' && printf 0 || printf 1)"

version_resolved_rc=0
version_resolved_out="$(env -u OCG_CODEGEN_DIR CODEGEN_DIR="$CODEGEN" "$NOWHERE_DIR/codegen-log" --version)" || version_resolved_rc=$?
assert "--version exits 0 when root resolves" "0" "$version_resolved_rc"
assert "--version reports resolved when CODEGEN_DIR set" "0" "$(printf '%s' "$version_resolved_out" | grep -qF 'root=resolved' && printf 0 || printf 1)"

# Test 16: ambiguous --slug (two logs matching the same slug) exits 2.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
dup1="$PROJECT/codegen/logging/20260106_000000_dup-slug_cycle.jsonl"
dup2="$PROJECT/codegen/logging/20260106_000100_dup-slug_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"dup-slug",path:"",stamp:{}}' >"$dup1"
jq -c -n '{ev:"init",pitch:"dup-slug",path:"",stamp:{}}' >"$dup2"
dup_rc=0
(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append developer-phoenix-backend --slug dup-slug --body @- <<<"x" >/dev/null 2>&1) || dup_rc=$?
assert "ambiguous slug exits 2" "2" "$dup_rc"
rm -f "$dup1" "$dup2"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
