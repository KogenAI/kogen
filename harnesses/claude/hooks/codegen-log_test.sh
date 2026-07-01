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
export AGENT_TYPE="developer-phoenix-backend"
section_out="$(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section --body @- <<'EOF'
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
export AGENT_TYPE="developer-phoenix-backend"
(
    cd "$PROJECT" && env -u CODEGEN_BUILD_CWD -u CLAUDE_PROJECT_DIR "$CODEGEN/codegen-log" section --body @- <<'EOF'
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

echo ""
echo "Results: $pass passed, $fail failed"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
