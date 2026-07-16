#!/bin/bash
# codegen-log_test.sh — unit tests for codegen-log (JSONL cycle-log storage)
#
# Topology under test: PROJECT (downstream app cwd) != CODEGEN (script install
# dir). This reproduces the split-brain bug where codegen-log resolved logs
# relative to SCRIPT_DIR (the launcher's install dir) instead of the project
# cwd. A self-build fixture (cwd == codegen repo == SCRIPT_DIR) makes this bug
# invisible, so every fixture here uses two distinct roots.

set -euo pipefail

# Neutralize an ambient CODEGEN_LOG_PATH pin from the launching (this very)
# dev session — codegen-log's highest-precedence resolver. Left set, several
# fixtures below (which invoke `init`/`section` without an explicit `env -u
# CODEGEN_LOG_PATH`) would silently redirect into the live session's own
# cycle log instead of the per-test PROJECT fixture, and the new `init`
# refusal-under-pin case would spuriously refuse. Unsetting once here is
# exhaustive.
unset CODEGEN_LOG_PATH

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

# Test 8b: --plan-gate/--files-to-touch/--files-modified emit structured
# events the gate-select/read-discipline reader hooks jq-select for.
plan_gate_out="$(
    cd "$PROJECT" && printf '{"command":"make ci","mode":"short","timeout":900}' |
        env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role planner-phoenix --slug marker-flags --plan-gate @-
)"
plan_gate_path="$(printf '%s' "$plan_gate_out" | tail -n 1)"
assert "--plan-gate wrote to the marker-flags log" "0" "$([ "$plan_gate_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--plan-gate emits exactly one plan_gate event" "1" "$(jq_count "$marker_log" 'select(.ev=="plan_gate" and .role=="planner-phoenix")')"
assert "--plan-gate command field" "0" "$([ "$(jq -r 'select(.ev=="plan_gate")|.command' "$marker_log")" = "make ci" ] && printf 0 || printf 1)"
assert "--plan-gate mode field" "0" "$([ "$(jq -r 'select(.ev=="plan_gate")|.mode' "$marker_log")" = "short" ] && printf 0 || printf 1)"
assert "--plan-gate timeout field" "0" "$([ "$(jq -r 'select(.ev=="plan_gate")|.timeout' "$marker_log")" = "900" ] && printf 0 || printf 1)"

set +e
plan_gate_bad_rc=0
(cd "$PROJECT" && printf 'not json' |
    env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role planner-phoenix --slug marker-flags --plan-gate @-) >/dev/null 2>&1
plan_gate_bad_rc=$?
set -e
assert "--plan-gate malformed JSON exits 2" "2" "$plan_gate_bad_rc"
assert "--plan-gate malformed JSON writes no new event" "1" "$(jq_count "$marker_log" 'select(.ev=="plan_gate")')"

files_to_touch_out="$(
    cd "$PROJECT" && printf '["context/foo.md","lib/bar.ex"]' |
        env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role planner-phoenix --slug marker-flags --files-to-touch @-
)"
files_to_touch_path="$(printf '%s' "$files_to_touch_out" | tail -n 1)"
assert "--files-to-touch wrote to the marker-flags log" "0" "$([ "$files_to_touch_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--files-to-touch emits exactly one event" "1" "$(jq_count "$marker_log" 'select(.ev=="files_to_touch" and .role=="planner-phoenix")')"
assert "--files-to-touch array count" "0" "$([ "$(jq -r 'select(.ev=="files_to_touch")|.files|length' "$marker_log")" = "2" ] && printf 0 || printf 1)"

files_modified_out="$(
    cd "$PROJECT" && printf '["lib/bar.ex"]' |
        env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role developer-phoenix-backend --slug marker-flags --files-modified @-
)"
files_modified_path="$(printf '%s' "$files_modified_out" | tail -n 1)"
assert "--files-modified wrote to the marker-flags log" "0" "$([ "$files_modified_path" = "$marker_log" ] && printf 0 || printf 1)"
assert "--files-modified emits exactly one event" "1" "$(jq_count "$marker_log" 'select(.ev=="files_modified" and .role=="developer-phoenix-backend")')"

set +e
mutex_rc=0
(cd "$PROJECT" && printf '{"command":"make ci","mode":"short","timeout":900}' |
    env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append --role planner-phoenix --slug marker-flags --plan-gate @- --learned "text") >/dev/null 2>&1
mutex_rc=$?
set -e
assert "--plan-gate + --learned mutually exclusive exits 2" "2" "$mutex_rc"

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

# Test 13: `verdict` appends a "gate" event (role="dev-gate") — the Elixir
# loop's LoopGate sole-writer routing target — and APPENDS a new event on
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

# Test 17: --slug "" (explicitly empty, e.g. an unset shell var expanding
# into the flag) must FAIL CLOSED — never silently fall back to the newest
# log. Pre-existing unrelated log must gain zero new role events.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
empty_slug_log="$PROJECT/codegen/logging/20260107_000000_unrelated-slug_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"unrelated-slug",path:"",stamp:{}}' >"$empty_slug_log"
empty_slug_rc=0
(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug "" --body @- <<<"should not land anywhere" >/dev/null 2>&1) || empty_slug_rc=$?
assert "explicit empty --slug exits 2" "2" "$empty_slug_rc"
assert "explicit empty --slug did not write into the newest unrelated log" "0" "$(jq_count "$empty_slug_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"

# Test 18: omitting --slug entirely is the sanctioned manual-CLI path and
# MUST keep resolving via the newest-mtime fallback (not fail closed). Clear
# every other *_cycle.jsonl fixture left behind by earlier tests so the
# mtime-fallback outcome is deterministic (only empty_slug_log remains).
find "$PROJECT/codegen/logging" -maxdepth 1 -name '*_cycle.jsonl' ! -name "$(basename "$empty_slug_log")" -delete
touch "$empty_slug_log"
omitted_slug_rc=0
omitted_slug_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --body @- <<<"### What I Learned This Step
- omitted slug still resolves" 2>&1)" || omitted_slug_rc=$?
assert "omitted --slug exits 0 (still resolves)" "0" "$omitted_slug_rc"
omitted_slug_path="$(printf '%s' "$omitted_slug_out" | tail -n 1)"
assert "omitted --slug landed on the newest-mtime log" "0" "$([ "$omitted_slug_path" = "$empty_slug_log" ] && printf 0 || printf 1)"
rm -f "$empty_slug_log"

# Test 19: --slug "" PLUS CODEGEN_LOG_PATH set must resolve via
# CODEGEN_LOG_PATH (highest precedence) — the fail-closed check in Test 17
# must sit AFTER the CODEGEN_LOG_PATH early-return, not before it, or a
# role pinned via CODEGEN_LOG_PATH (whose own --slug may be empty) would be
# wrongly rejected.
pinned_log="$PROJECT/codegen/logging/20260108_000000_pinned-slug_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"pinned-slug",path:"",stamp:{}}' >"$pinned_log"
pinned_rc=0
pinned_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR CODEGEN_LOG_PATH="$pinned_log" "$CODEGEN/codegen-log" section developer-phoenix-backend --slug "" --body @- <<<"pinned via CODEGEN_LOG_PATH despite empty --slug" 2>&1)" || pinned_rc=$?
assert "CODEGEN_LOG_PATH + empty --slug exits 0" "0" "$pinned_rc"
pinned_path="$(printf '%s' "$pinned_out" | tail -n 1)"
assert "CODEGEN_LOG_PATH + empty --slug wrote to the pinned log" "0" "$([ "$pinned_path" = "$pinned_log" ] && printf 0 || printf 1)"
assert "CODEGEN_LOG_PATH + empty --slug body landed" "1" "$(jq_count "$pinned_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
rm -f "$pinned_log"

# Test 20: `section <role> --learned "<text>"` emits BOTH a "role" event
# (from --body/stdin) AND a "learned" event, in one call. `section` without
# --learned emits only the "role" event and NEVER refuses the write.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
section_learned_log="$PROJECT/codegen/logging/20260109_000000_section-learned_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"section-learned",path:"",stamp:{}}' >"$section_learned_log"
section_learned_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug section-learned --learned "learned something genuinely useful this step" <<'EOF'
did the work this step
EOF
)"
section_learned_path="$(printf '%s' "$section_learned_out" | tail -n 1)"
assert "section --learned wrote to the section-learned log" "0" "$([ "$section_learned_path" = "$section_learned_log" ] && printf 0 || printf 1)"
assert "section --learned emits exactly one role event" "1" "$(jq_count "$section_learned_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
assert "section --learned emits exactly one learned event" "1" "$(jq_count "$section_learned_log" 'select(.ev=="learned" and .role=="developer-phoenix-backend")')"
assert "section --learned role body landed" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$section_learned_log" | grep -qF 'did the work this step' && printf 0 || printf 1)"
assert "section --learned learned text matches" "0" "$([ "$(jq -r 'select(.ev=="learned")|.text' "$section_learned_log")" = "learned something genuinely useful this step" ] && printf 0 || printf 1)"

section_no_learned_log="$PROJECT/codegen/logging/20260109_000001_section-no-learned_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"section-no-learned",path:"",stamp:{}}' >"$section_no_learned_log"
cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug section-no-learned <<'EOF' >/dev/null
no learned flag here
EOF
assert "section without --learned emits exactly one role event" "1" "$(jq_count "$section_no_learned_log" 'select(.ev=="role" and .role=="developer-phoenix-backend")')"
assert "section without --learned emits zero learned events (never refuses)" "0" "$(jq_count "$section_no_learned_log" 'select(.ev=="learned")')"

# Test 21: `init` refuses (exit 2) when CODEGEN_LOG_PATH is set — creates no
# new file, and .active is byte-identical before/after (never hijacked). This
# is the fix for the cycle-20260714_182153 failure: a role re-running `init`
# with a mistyped slug must not be able to mint a rival log and repoint the
# sentinel out from under every guard grading the real one.
pinned_log="$PROJECT/codegen/logging/20260110_000000_pinned-real_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"pinned-real",path:"",stamp:{}}' >"$pinned_log"
printf '%s' "$pinned_log" >"$PROJECT/codegen/logging/.active"
active_before="$(cat "$PROJECT/codegen/logging/.active")"
files_before="$(find "$PROJECT/codegen/logging" -name '*_cycle.jsonl' | sort)"
init_refuse_rc=0
init_refuse_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR CODEGEN_LOG_PATH="$pinned_log" "$CODEGEN/codegen-log" init --slug rival-typo-slug 2>&1
)" || init_refuse_rc=$?
assert "init under CODEGEN_LOG_PATH pin exits 2" "2" "$init_refuse_rc"
assert "init refusal message names the pin" "0" "$(printf '%s' "$init_refuse_out" | grep -qF "$pinned_log" && printf 0 || printf 1)"
files_after="$(find "$PROJECT/codegen/logging" -name '*_cycle.jsonl' | sort)"
assert "init refusal created no new *_cycle.jsonl file" "0" "$([ "$files_before" = "$files_after" ] && printf 0 || printf 1)"
active_after="$(cat "$PROJECT/codegen/logging/.active")"
assert "init refusal left .active byte-identical" "0" "$([ "$active_before" = "$active_after" ] && printf 0 || printf 1)"

# Test 22: `show` read-only render — default table, --format md/html
# (html escapes special chars), --role drill-down, --full.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
show_log="$PROJECT/codegen/logging/20260111_000000_show-render_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-render",path:"",stamp:{}}' >"$show_log"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug show-render --learned "learned something real this step" <<'EOF' >/dev/null
did the work
EOF
)
table_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-render)"
assert "table render shows the role" "0" "$(printf '%s' "$table_show" | grep -qF 'developer-phoenix-backend' && printf 0 || printf 1)"
assert "table render shows no anomalies" "0" "$(printf '%s' "$table_show" | grep -qF 'no anomalies' && printf 0 || printf 1)"
assert "table render shows totals line" "0" "$(printf '%s' "$table_show" | grep -qF 'role invocations' && printf 0 || printf 1)"

md_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-render --format md)"
assert "md render has a markdown table header" "0" "$(printf '%s' "$md_show" | grep -qF '| # | Role |' && printf 0 || printf 1)"

html_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-render --format html)"
assert "html render contains a table tag" "0" "$(printf '%s' "$html_show" | grep -qF '<table' && printf 0 || printf 1)"

show_escape_log="$PROJECT/codegen/logging/20260111_000100_show-html-escape_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-html-escape",path:"",stamp:{}}' >"$show_escape_log"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug show-html-escape --learned "text with < and & escaped in html output" <<'EOF' >/dev/null
body with <script>&amp;
EOF
)
html_escape_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-html-escape --format html --full)"
assert "html --full escapes body content" "0" "$(printf '%s' "$html_escape_show" | grep -qF '&lt;' && printf 0 || printf 1)"

role_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-render --role developer-phoenix-backend)"
assert "--role drill-down shows the body" "0" "$(printf '%s' "$role_show" | grep -qF 'did the work' && printf 0 || printf 1)"
assert "--role drill-down shows learned text" "0" "$(printf '%s' "$role_show" | grep -qF 'learned something real this step' && printf 0 || printf 1)"

full_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-render --full)"
assert "--full shows role section marker" "0" "$(printf '%s' "$full_show" | grep -qF '=== developer-phoenix-backend ===' && printf 0 || printf 1)"

# Test 23: `show` anomaly detection — cycle-summary-only role (no ev:role
# body) and a role with neither learned nor no_learning both surface; a
# clean cycle prints "no anomalies".
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
anomaly_log="$PROJECT/codegen/logging/20260111_000200_show-anomalies_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-anomalies",path:"",stamp:{}}' >"$anomaly_log"
anomaly_stem="${anomaly_log%_cycle.jsonl}"
mkdir -p "$anomaly_stem"
cat >"$anomaly_stem/cycle-summary.jsonl" <<'SUMMARY'
{"cost_usd":0.1,"num_turns":3,"role":"committer","seq":1,"status":"success","transcript":"/tmp/c.jsonl"}
SUMMARY
anomaly_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-anomalies)"
assert "invoked-but-no-body anomaly fires for committer" "0" "$(printf '%s' "$anomaly_show" | grep -qF 'committer: invoked but wrote no body' && printf 0 || printf 1)"
assert "no-learned/no_learning anomaly fires for committer" "0" "$(printf '%s' "$anomaly_show" | grep -qF 'no learned/no_learning event' && printf 0 || printf 1)"

clean_log="$PROJECT/codegen/logging/20260111_000300_show-clean_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-clean",path:"",stamp:{}}' >"$clean_log"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug show-clean --learned "clean cycle, real learning text here" <<'EOF' >/dev/null
clean work
EOF
)
clean_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-clean)"
assert "clean cycle prints literal no anomalies" "0" "$(printf '%s' "$clean_show" | grep -qF 'no anomalies' && printf 0 || printf 1)"

# Test 24: `show` degrades deterministically — no sibling summary dir -> "—"
# + stderr note, exit 0; unknown ev kind counted and reported, never dropped.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
nosum_log="$PROJECT/codegen/logging/20260111_000400_show-no-summary_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-no-summary",path:"",stamp:{}}' >"$nosum_log"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug show-no-summary --learned "no summary sibling exists for this cycle" <<'EOF' >/dev/null
solo body
EOF
)
nosum_stderr_file="$TMP_DIR/show-no-summary.stderr"
nosum_rc=0
nosum_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-no-summary 2>"$nosum_stderr_file")" || nosum_rc=$?
assert "missing-sibling show exits 0" "0" "$nosum_rc"
assert "missing-sibling turns render as em dash" "0" "$(printf '%s' "$nosum_out" | grep -qF '—' && printf 0 || printf 1)"
assert "missing-sibling stderr names the missing dir" "0" "$(grep -qF 'no cycle-summary.jsonl sibling found' "$nosum_stderr_file" && printf 0 || printf 1)"

printf '%s\n' '{"ev":"mystery-kind","foo":"bar"}' >>"$nosum_log"
unknown_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-no-summary)"
assert "unknown ev kind reported, not dropped" "0" "$(printf '%s' "$unknown_show" | grep -qF 'other events: mystery-kindx1' && printf 0 || printf 1)"

# Test 25: `show` error paths — bad --format exits 2; unknown --role exits
# 2; malformed log line exits non-zero (no partial render).
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
err_log="$PROJECT/codegen/logging/20260111_000500_show-errors_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-errors",path:"",stamp:{}}' >"$err_log"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug show-errors --body @- <<<"body" >/dev/null
)

format_rc=0
format_err="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-errors --format zzz 2>&1)" || format_rc=$?
assert "bad --format exits 2" "2" "$format_rc"
assert "bad --format error names allowed values" "0" "$(printf '%s' "$format_err" | grep -qF 'table|md|html' && printf 0 || printf 1)"

role_rc=0
role_err="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-errors --role bogus-role-xyz 2>&1)" || role_rc=$?
assert "unknown --role exits 2" "2" "$role_rc"
assert "unknown --role error names the role" "0" "$(printf '%s' "$role_err" | grep -qF 'bogus-role-xyz' && printf 0 || printf 1)"

printf '%s\n' 'not valid json' >>"$err_log"
malformed_rc=0
(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-errors >/dev/null 2>&1) || malformed_rc=$?
assert "malformed log line exits non-zero" "0" "$([ "$malformed_rc" -ne 0 ] && printf 0 || printf 1)"

# Test 26: `show` invoked-but-no-body anomaly under the ROLE-spine fallback
# (no ev:turn events, no cycle-summary.jsonl sibling): a role that only has
# a died event (invoked, then dropped before ever writing a body) must still
# trip "invoked but wrote no body" — this is the exact branch that was dead
# code before the fix (it only ever fired via .turn, which is always null
# on the role spine).
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
rolespine_log="$PROJECT/codegen/logging/20260111_000600_show-role-spine-anomaly_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"show-role-spine-anomaly",path:"",stamp:{}}' >"$rolespine_log"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug show-role-spine-anomaly --learned "role-spine fallback fixture, real learning text" <<'EOF' >/dev/null
clean work
EOF
)
(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append committer --slug show-role-spine-anomaly --died interrupted --cause "session dropped before writing anything" >/dev/null)
rolespine_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug show-role-spine-anomaly)"
assert "role-spine fallback is actually in use (no ev:turn, no summary sibling)" "0" "$(printf '%s' "$rolespine_show" | grep -qF 'spine: role' && printf 0 || printf 1)"
assert "invoked-but-no-body anomaly fires for committer under role-spine fallback" "0" "$(printf '%s' "$rolespine_show" | grep -qF 'committer: invoked but wrote no body' && printf 0 || printf 1)"

# Test 27: two inits, same slug, different stamps -> two distinct logs; the
# first gains zero events (the run-identity fix's core invariant — a retry
# must never be silently absorbed into its predecessor's log).
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
run1_path="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug retry-run-identity --stamp 20260201_010000)"
run2_path="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug retry-run-identity --stamp 20260201_020000)"
assert "two inits, same slug, different stamps, produce different paths" "0" "$([ "$run1_path" != "$run2_path" ] && printf 0 || printf 1)"
assert "run1 log exists" "0" "$([ -f "$run1_path" ] && printf 0 || printf 1)"
assert "run2 log exists" "0" "$([ -f "$run2_path" ] && printf 0 || printf 1)"
run1_lines="$(wc -l <"$run1_path" | tr -d ' ')"
assert "run1 log still carries only its own single init event" "1" "$run1_lines"

# Test 28: --stamp composes the exact path.
unset CODEGEN_LOG_PATH
exact_path="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug exact-stamp-path --stamp 20260301_093000)"
assert "--stamp composes the exact path" "$PROJECT/codegen/logging/20260301_093000_exact-stamp-path_cycle.jsonl" "$exact_path"

# Test 29: --stamp naming an existing log adopts it — exit 0, prints that
# path, .active rewritten, no second file, no duplicate ev:init line.
unset CODEGEN_LOG_PATH
adopt_first="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug adopt-same-stamp --stamp 20260302_100000)"
files_before_adopt="$(find "$PROJECT/codegen/logging" -name '*adopt-same-stamp*_cycle.jsonl' | sort)"
adopt_second="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug adopt-same-stamp --stamp 20260302_100000)"
files_after_adopt="$(find "$PROJECT/codegen/logging" -name '*adopt-same-stamp*_cycle.jsonl' | sort)"
assert "adopt: same slug+stamp re-init returns the same path" "$adopt_first" "$adopt_second"
assert "adopt: no second file was created" "0" "$([ "$files_before_adopt" = "$files_after_adopt" ] && printf 0 || printf 1)"
adopt_lines="$(wc -l <"$adopt_first" | tr -d ' ')"
assert "adopt: no duplicate init event was appended" "1" "$adopt_lines"
adopt_active="$(cat "$PROJECT/codegen/logging/.active")"
assert "adopt: .active rewritten to the adopted log" "$adopt_first" "$adopt_active"

# Test 30: malformed --stamp exits 2, creates no file. Cases: hyphens instead
# of underscore separator, no underscore at all, non-numeric garbage.
for bad_stamp in "2026-02-01_120000" "20260201120000" "abc"; do
    unset CODEGEN_LOG_PATH
    files_before_bad="$(find "$PROJECT/codegen/logging" -name '*bad-stamp-case*_cycle.jsonl' 2>/dev/null | sort)"
    bad_rc=0
    (cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug bad-stamp-case --stamp "$bad_stamp" >/dev/null 2>&1) || bad_rc=$?
    assert "malformed --stamp '$bad_stamp' exits 2" "2" "$bad_rc"
    files_after_bad="$(find "$PROJECT/codegen/logging" -name '*bad-stamp-case*_cycle.jsonl' 2>/dev/null | sort)"
    assert "malformed --stamp '$bad_stamp' created no file" "0" "$([ "$files_before_bad" = "$files_after_bad" ] && printf 0 || printf 1)"
done

# Test 31: `show <slug>` across two same-slug logs -> exit 0, renders the
# newest run, and stderr carries ONE note naming the older.
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
show_run1="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug retried-show-slug --stamp 20260401_010000)"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR CODEGEN_LOG_PATH="$show_run1" "$CODEGEN/codegen-log" section developer-phoenix-backend --learned "first attempt learning, real content here" <<'EOF' >/dev/null
first attempt work
EOF
)
show_run2="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" init --slug retried-show-slug --stamp 20260401_020000)"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR CODEGEN_LOG_PATH="$show_run2" "$CODEGEN/codegen-log" section developer-phoenix-backend --learned "second attempt learning, real content here" <<'EOF' >/dev/null
second attempt work
EOF
)
unset CODEGEN_LOG_PATH
show_retried_rc=0
show_retried_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug retried-show-slug --full 2>"$TMP_DIR/show_retried_stderr")" || show_retried_rc=$?
assert "show across a retried slug exits 0" "0" "$show_retried_rc"
assert "show across a retried slug renders the newest run's body" "0" "$(printf '%s' "$show_retried_out" | grep -qF 'second attempt work' && printf 0 || printf 1)"
assert "show across a retried slug does not render the older run's body" "0" "$(printf '%s' "$show_retried_out" | grep -qF 'first attempt work' && printf 1 || printf 0)"
show_retried_stderr="$(cat "$TMP_DIR/show_retried_stderr")"
assert "show across a retried slug notes the older log on stderr" "0" "$(printf '%s' "$show_retried_stderr" | grep -qF "$show_run1" && printf 0 || printf 1)"
assert "show across a retried slug names the newest log in the note" "0" "$(printf '%s' "$show_retried_stderr" | grep -qF "$show_run2" && printf 0 || printf 1)"

# Test 32: `exit` appends a process-level "exit" event with NO role field.
# --status required; --signal/--stderr-tail optional. Resolution mirrors
# section/append EXCEPT unresolvable -> exit 0, writes nothing (loud stderr
# note instead of a hard failure — the loop may have died before init).
unset CODEGEN_LOG_PATH
unset AGENT_TYPE
exit_log="$PROJECT/codegen/logging/20260112_000000_exit-record_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"exit-record",path:"",stamp:{}}' >"$exit_log"

exit_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" exit --slug exit-record --status 1 --signal 0 --stderr-tail "boom: RuntimeError"
)"
exit_path="$(printf '%s' "$exit_out" | tail -n 1)"
assert "exit wrote to the exit-record log" "0" "$([ "$exit_path" = "$exit_log" ] && printf 0 || printf 1)"
assert "exit emits exactly one exit event" "1" "$(jq_count "$exit_log" 'select(.ev=="exit")')"
assert "exit event carries no role field" "0" "$([ "$(jq -r 'select(.ev=="exit")|has("role")' "$exit_log")" = "false" ] && printf 0 || printf 1)"
assert "exit status field" "0" "$([ "$(jq -r 'select(.ev=="exit")|.status' "$exit_log")" = "1" ] && printf 0 || printf 1)"
assert "exit stderr_tail field" "0" "$([ "$(jq -r 'select(.ev=="exit")|.stderr_tail' "$exit_log")" = "boom: RuntimeError" ] && printf 0 || printf 1)"

cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" exit --slug exit-record --status 137 --signal 9 >/dev/null
assert "exit signal death carries signal=9" "1" "$(jq_count "$exit_log" 'select(.ev=="exit" and .status==137 and .signal==9)')"

set +e
exit_missing_status_rc=0
(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" exit --slug exit-record) >/dev/null 2>&1
exit_missing_status_rc=$?
set -e
assert "exit without --status exits 2" "2" "$exit_missing_status_rc"

# exit unresolvable (no --slug, no .active, no logs at all in a fresh empty
# project root) -> exit 0, writes nothing, loud stderr note.
NOLOG_PROJECT="$TMP_DIR/nolog-project"
mkdir -p "$NOLOG_PROJECT/codegen/logging"
exit_norecord_rc=0
exit_norecord_stderr="$(
    cd "$NOLOG_PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" exit --status 1 2>&1 1>/dev/null
)" || exit_norecord_rc=$?
assert "exit with unresolvable log exits 0 (not a hard failure)" "0" "$exit_norecord_rc"
assert "exit with unresolvable log notes the skip on stderr" "0" "$(printf '%s' "$exit_norecord_stderr" | grep -qF 'not recorded' && printf 0 || printf 1)"
assert "exit with unresolvable log wrote no file" "0" "$([ -z "$(find "$NOLOG_PROJECT/codegen/logging" -name '*_cycle.jsonl' 2>/dev/null)" ] && printf 0 || printf 1)"

# Test 33: known_kinds drift fix — plan_gate/files_to_touch/files_modified/exit
# no longer render as "other events:" in `show` — they were previously
# missing from the known-kinds allowlist despite being first-class writers.
unset CODEGEN_LOG_PATH
drift_log="$PROJECT/codegen/logging/20260112_000100_known-kinds-drift_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"known-kinds-drift",path:"",stamp:{}}' >"$drift_log"
jq -c -n '{ev:"role",role:"planner-phoenix",body:"plan body"}' >>"$drift_log"
jq -c -n '{ev:"plan_gate",role:"planner-phoenix",command:"make ci",mode:"short",timeout:900}' >>"$drift_log"
jq -c -n '{ev:"files_to_touch",role:"planner-phoenix",files:["a.ex"]}' >>"$drift_log"
jq -c -n '{ev:"files_modified",role:"developer-phoenix-backend",files:["a.ex"]}' >>"$drift_log"
jq -c -n '{ev:"exit",status:0,signal:null,stderr_tail:""}' >>"$drift_log"
drift_show="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" show --slug known-kinds-drift 2>/dev/null)"
assert "show no longer reports plan_gate/files_to_touch/files_modified/exit as unknown" \
    "0" "$(printf '%s' "$drift_show" | grep -qF 'other events:' && printf 1 || printf 0)"

# Test 34: --body accepts literal text directly (no leading @) — the
# naturally-typed form. @- and @<path> keep their existing meanings.
unset CODEGEN_LOG_PATH
literal_log="$PROJECT/codegen/logging/20260113_000000_literal-body_cycle.jsonl"
jq -c -n '{ev:"init",pitch:"literal-body",path:"",stamp:{}}' >"$literal_log"

literal_section_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug literal-body --body "plain literal text, no @ prefix")"
literal_rc=$?
literal_section_path="$(printf '%s' "$literal_section_out" | tail -n 1)"
assert "section --body <literal text> exits 0" "0" "$literal_rc"
assert "section --body <literal text> wrote to the targeted log" "0" "$([ "$literal_section_path" = "$literal_log" ] && printf 0 || printf 1)"
assert "section --body <literal text> body matches the literal text verbatim" "0" "$(jq -r --arg r developer-phoenix-backend 'select(.ev=="role" and .role==$r)|.body' "$literal_log" | grep -qxF 'plain literal text, no @ prefix' && printf 0 || printf 1)"

literal_append_out="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" append developer-phoenix-backend --slug literal-body --body "appended literal text")"
literal_append_rc=$?
assert "append --body <literal text> exits 0" "0" "$literal_append_rc"
assert "append --body <literal text> appended a second role event with the literal text" "1" "$(jq_count "$literal_log" 'select(.ev=="role" and .role=="developer-phoenix-backend" and .body=="appended literal text")')"

# Test 35: --body @<missing-file> still fails loud (literal-text acceptance
# must not silently swallow a genuine @-prefixed source that fails to read).
missing_file_stderr="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section developer-phoenix-backend --slug literal-body --body @/no/such/file-xyz 2>&1 1>/dev/null)" || missing_file_rc=$?
assert "section --body @<missing file> still exits 2" "2" "${missing_file_rc:-0}"
assert "section --body @<missing file> still names the missing file" "0" "$(printf '%s' "$missing_file_stderr" | grep -qF 'body file not found' && printf 0 || printf 1)"

# Test 36: bare `codegen-log` with no subcommand names the problem before the
# Usage: dump (previously a bare Usage: block with zero reason line).
nosub_stderr="$(cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" 2>&1 1>/dev/null)" || nosub_rc=$?
assert "no-subcommand invocation exits 2" "2" "${nosub_rc:-0}"
assert "no-subcommand invocation names the problem before Usage:" "0" "$(printf '%s' "$nosub_stderr" | grep -qF 'no subcommand given' && printf 0 || printf 1)"
assert "no-subcommand Usage: block shows the taught positional-stdin form" "0" "$(printf '%s' "$nosub_stderr" | grep -qF 'codegen-log section <role>' && printf 0 || printf 1)"

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
